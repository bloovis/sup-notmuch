require 'set'
require 'fileutils'
require 'monitor'
require 'json'

require "sup/util/query"
require "sup/hook"
require "sup/logger/singleton"

require 'open3'
require 'shellwords'

module Redwood

class Notmuch
  include Redwood::Singleton

  HookManager.register "custom-search", <<EOS
Executes before a string search is applied to the index,
returning a new search string.
Variables:
  subs: The string being searched.
EOS

  # low-level
  def get_config(name)
    run('config', 'get', name).lines.map(&:chomp)
  end

  def set_config(name, value)
    run('config', 'set', name, [*value].join(';'))
  end

  def lastmod # lastmod (ignored uuid for convenience)
    run('count', '--lastmod').split.last.to_i
  end

  def poll
    run('new', '--quiet', check_stderr: false)
  end

  # Run "notmuch insert" to store a message in the specified
  # folder (which can be nil).  Supply a block that takes
  # an IO object; the block should write the message contents
  # to the IO.  Return true if successful, or false otherwise.

  def insert(folder)	# supply a block that takes an IO
    cmd = "notmuch insert "
    if folder
      cmd << "--create-folder --folder=#{folder}"
    end
    pipe = IO.popen(cmd, "w:UTF-8")
    if pipe
      yield pipe
      pipe.close
      stored = true
      Notmuch.poll
      PollManager.poll
      return true
    else
      debug "Unable to pipe to #{cmd}"
      return false
    end
    # Code used to look like this:
    #   run('insert', '--create-folder', input: data)
  end

  def count(*query)
    run('count', *query).to_i
  end

  def address(*query, limit: 20)
    run('address', '--format=text', *query, filter: "head -n #{limit}").lines.uniq.map {|a| Person.from_address a.chomp}
  end

  def search(*query, **kwargs)
    if query[1]
      kwargs = query[1]
      query[1] = nil
    end
    format = kwargs[:format] || 'text'
    exclude = kwargs[:exclude] || true
    output = kwargs[:output] || 'threads'
    offset = kwargs[:offset] || nil
    limit = kwargs[:limit] || nil
    debug "search: query #{query}, offset #{offset}, limit #{limit}"
  # search threads, return thread ids
    flags = ["--format=#{format}", "--output=#{output}"]
    flags << "--offset=#{offset}" unless offset.nil?
    flags << "--limit=#{limit}" unless limit.nil?
    flags << '--exclude=false' if exclude == false
    run('search', *flags, *query).lines.map(&:chomp)
  end

  def show(*query, body: false)
    # query: usually just a thread id
    JSON.parse(run('show', '--format=json', "--body=#{body}", *query), max_nesting: false)
  end

  def tag(*query)
    run('tag', *query)
  end

  def tag_batch(query_tags)
    return if query_tags.empty?
    input = query_tags.map do |q, ls|
      "#{ls.map{|l| "+#{l} "}.join} -- #{q}\n"
    end.join
    @@logger.debug("tag input: #{input}") if @@logger
    debug "tag_batch input: #{input}"
    run('tag', '--remove-all', '--batch', input: input)
  end

  # high-level

  def filenames_from_message_id mid
    search("id:#{mid}", exclude: false, format: 'text', output: 'files', limit: 1)
  end

  def thread_id_from_message_id mid
    search("id:#{mid}", exclude: false, format: 'text', output: 'threads', limit: 1)[0]
  end

  def tags_from_message_id mid
    search("id:#{mid}", exclude: false, output: 'tags')
  end

  def save_thread t
    Message.sync_back_labels t.messages
  end

  def load_contacts(email_addresses, limit=20)
    key = "#{email_addresses}"
    @@contact_cache ||= { key => [] }
    if (@@contact_cache[key] || []).size < limit
      query = email_addresses.map{|e| "from:#{e} or to:#{e}"}.join(' ')
      # note: using notmuch to get a list of contact is very slow, so don't do it.
      #@@contact_cache[key] = address('--output=sender', '--output=recipients', query, limit: limit)
      #@@contact_cache[key] = address('--output=sender', query, limit: limit)
      @@contact_cache[key] = []
    end
    @@contact_cache[key][0, limit]
  end

  # translate a Sup query Hash to plain text (experimental)
  def convert_query(opts={})
    return opts if opts.is_a?(String)
    return '' if opts.empty?
    query = (opts[:translated] || '').gsub(/\blabel:/, 'tag:').gsub(/\B-tag:\w+/) do |t|
      "(not #{t[1..-1]})"
    end
    query << ([opts[:label]] + (opts[:labels] || [])).compact.map {|l| " tag:#{l}"}.join('')
    %w[spam deleted killed].each do |tag|
       loadtag = opts["load_#{tag}".to_sym] || (opts["skip_#{tag}".to_sym] == false)
       query << " (not tag:#{tag})" if !loadtag && !query.include?("tag:#{tag}")
    end
    query
  end

  # (Moved from the old IndexManager)
  ## parse a query string from the user. returns a query object
  ## that can be passed to any index method with a 'query'
  ## argument.
  ##
  ## raises a ParseError if something went wrong.
  class ParseError < StandardError; end

  def parse_query s
    query = {}

    subs = HookManager.run("custom-search", :subs => s) || s
    begin
      subs = SearchManager.expand subs
    rescue SearchManager::ExpansionError => e
      raise ParseError, e.message
    end
    subs = subs.gsub(/\b(to|from):(\S+)\b/) do
      field, value = $1, $2
      p = ContactManager.contact_for(value)
      if p
        "#{field}:#{p.email}"
      elsif value == "me"
        '(' + AccountManager.user_emails.map { |e| "#{field}:#{e}" }.join(' OR ') + ')'
      else
        "#{field}:#{value}"
      end
    end

    ## gmail style "is" operator
    subs = subs.gsub(/\b(is|has):(\S+)\b/) do
      field, label = $1, $2
      case label
      when "read"
        "-label:unread"
      when "spam"
        query[:load_spam] = true
        "label:spam"
      when "deleted"
        query[:load_deleted] = true
        "label:deleted"
      else
        "label:#{$2}"
      end
    end

    ## labels are stored lower-case in the index
    subs = subs.gsub(/\blabel:(\S+)\b/) do
      label = $1
      "label:#{label.downcase}"
    end

    ## if we see a label:deleted or a label:spam term anywhere in the query
    ## string, we set the extra load_spam or load_deleted options to true.
    ## bizarre? well, because the query allows arbitrary parenthesized boolean
    ## expressions, without fully parsing the query, we can't tell whether
    ## the user is explicitly directing us to search spam messages or not.
    ## e.g. if the string is -(-(-(-(-label:spam)))), does the user want to
    ## search spam messages or not?
    ##
    ## so, we rely on the fact that turning these extra options ON turns OFF
    ## the adding of "-label:deleted" or "-label:spam" terms at the very
    ## final stage of query processing. if the user wants to search spam
    ## messages, not adding that is the right thing; if he doesn't want to
    ## search spam messages, then not adding it won't have any effect.
    query[:load_spam] = true if subs =~ /\blabel:spam\b/
    query[:load_deleted] = true if subs =~ /\blabel:deleted\b/
    query[:load_killed] = true if subs =~ /\blabel:killed\b/

    ## gmail style attachments "filename" and "filetype" searches
    subs = subs.gsub(/\b(filename|filetype):(\((.+?)\)\B|(\S+)\b)/) do
      field, name = $1, ($3 || $4)
      case field
      when "filename"
        debug "filename: translated #{field}:#{name} to attachment:\"#{name.downcase}\""
        "attachment:\"#{name.downcase}\""
      when "filetype"
        debug "filetype: translated #{field}:#{name} to mimetype:#{name.downcase}"
        "mimetype:#{name.downcase}"
      end
    end

    lastdate = 2<<32 - 1
    firstdate = 0
    subs = subs.gsub(/\b(before|on|in|during|after):(\((.+?)\)\B|(\S+)\b)/) do
      field, datestr = $1, ($3 || $4)
      datestr.gsub!(/ /,'_')       # translate spaces to underscores
      case field
      when "after"
	"date:#{datestr}.."
      when "before"
	"date:..#{datestr}"
      else
	"date:#{datestr}..!"
      end
    end

    ## limit:42 restrict the search to 42 results
    subs = subs.gsub(/\blimit:(\S+)\b/) do
      lim = $1
      if lim =~ /^\d+$/
        query[:limit] = lim.to_i
        ''
      else
        raise ParseError, "non-numeric limit #{lim.inspect}"
      end
    end

    debug "translated query: #{subs.inspect}"
    query[:text] = s
    query[:translated] = subs
    query
  end
  private

  @@logger = if $config && $config[:notmuch_logfile]
               ::Logger.new($config[:notmuch_logfile])
             else
               nil
             end

  def run(*args, check_status: true, check_stderr: true, filter: nil, input: nil, **opts)
    args.reject! { |a| opts.merge!(a) if a.is_a?(Hash) }
    optstr = convert_query opts
    cmd = "notmuch #{Shellwords.join(args)}"
    cmd << " #{Shellwords.escape(optstr)}" unless optstr.empty?
    cmd << " | #{filter}" if filter
    debug "Running #{cmd}"
    if @@logger and cmd != 'notmuch count'
      @@logger.info(cmd)
    end
    stdout_str, stderr_str, status = Open3.capture3(cmd, stdin_data: input)
    if (check_status && !status.success?) || (check_stderr && !stderr_str.empty?)
      raise ParseError, "Failed to execute #{cmd}: exitcode=#{status.exitstatus}, stderr=#{stderr_str}"
    end
    stdout_str
  end

end

Notmuch.init

# This index implementation is just a placeholder for historic reasons. Notmuch
# would replace most of Index's features.
class Index

  # Stemmed
  NORMAL_PREFIX = {
    'subject' => {:prefix => 'S', :exclusive => false},
    'body' => {:prefix => 'B', :exclusive => false},
    'from_name' => {:prefix => 'FN', :exclusive => false},
    'to_name' => {:prefix => 'TN', :exclusive => false},
    'name' => {:prefix => %w(FN TN), :exclusive => false},
    'attachment' => {:prefix => 'A', :exclusive => false},
    'email_text' => {:prefix => 'E', :exclusive => false},
    '' => {:prefix => %w(S B FN TN A E), :exclusive => false},
  }

  # Unstemmed
  BOOLEAN_PREFIX = {
    'type' => {:prefix => 'K', :exclusive => true},
    'from_email' => {:prefix => 'FE', :exclusive => false},
    'to_email' => {:prefix => 'TE', :exclusive => false},
    'email' => {:prefix => %w(FE TE), :exclusive => false},
    'date' => {:prefix => 'D', :exclusive => true},
    'label' => {:prefix => 'L', :exclusive => false},
    'source_id' => {:prefix => 'I', :exclusive => true},
    'attachment_extension' => {:prefix => 'O', :exclusive => false},
    'msgid' => {:prefix => 'Q', :exclusive => true},
    'id' => {:prefix => 'Q', :exclusive => true},
    'thread' => {:prefix => 'H', :exclusive => false},
    'ref' => {:prefix => 'R', :exclusive => false},
    'location' => {:prefix => 'J', :exclusive => false},
  }

  PREFIX = NORMAL_PREFIX.merge BOOLEAN_PREFIX

  COMPL_OPERATORS = %w[AND OR NOT]
  COMPL_PREFIXES = (
    %w[
      from to
      is has label
      filename filetypem
      before on in during after
      limit
    ] + NORMAL_PREFIX.keys + BOOLEAN_PREFIX.keys
  ).map{|p|"#{p}:"} + COMPL_OPERATORS

  def save_message *args
    # TODO notmuch
    fail
  end
end

end
