# encoding: UTF-8

require 'time'

module Redwood

## a Message is what's threaded.
##
## it is also where the parsing for quotes and signatures is done, but
## that should be moved out to a separate class at some point (because
## i would like, for example, to be able to add in a ruby-talk
## specific module that would detect and link to /ruby-talk:\d+/
## sequences in the text of an email. (how sweet would that be?)

class Message
  SNIPPET_LEN = 80
  RE_PATTERN = /^((re|re[\[\(]\d[\]\)]):\s*)+/i

  ## some utility methods
  class << self
    def normalize_subj s; s.gsub(RE_PATTERN, ""); end
    def subj_is_reply? s; s =~ RE_PATTERN; end
    def reify_subj s; subj_is_reply?(s) ? s : "Re: " + s; end
  end

  QUOTE_PATTERN = /^\s{0,4}[>|\}]/
  BLOCK_QUOTE_PATTERN = /^-----\s*Original Message\s*----+$/
  SIG_PATTERN = /(^(- )*-- ?$)|(^\s*----------+\s*$)|(^\s*_________+\s*$)|(^\s*--~--~-)|(^\s*--\+\+\*\*==)/

  GPG_SIGNED_START = "-----BEGIN PGP SIGNED MESSAGE-----"
  GPG_SIGNED_END = "-----END PGP SIGNED MESSAGE-----"
  GPG_START = "-----BEGIN PGP MESSAGE-----"
  GPG_END = "-----END PGP MESSAGE-----"
  GPG_SIG_START = "-----BEGIN PGP SIGNATURE-----"
  GPG_SIG_END = "-----END PGP SIGNATURE-----"

  MAX_SIG_DISTANCE = 15 # lines from the end
  DEFAULT_SUBJECT = ""
  DEFAULT_SENDER = "(missing sender)"
  MAX_HEADER_VALUE_SIZE = 4096

  attr_reader :id, :date, :from, :orig_from, :subj, :refs, :replytos, :to,
              :cc, :bcc, :labels, :attachments, :list_address, :recipient_email, :replyto,
              :list_subscribe, :list_unsubscribe, :filename

  bool_reader :dirty, :dirty_labels, :source_marked_read, :snippet_contains_encrypted_content

  ## if you specify a :header, will use values from that. otherwise,
  ## will try and load the header from the source.
  def initialize opts={}
    @snippet = opts[:snippet]
    @snippet_contains_encrypted_content = false
    @have_snippet = !(opts[:snippet].nil? || opts[:snippet].empty?)
    @labels = Set.new((opts[:labels] || []).map(&:to_sym))
    @dirty = false
    @dirty_labels = false
    @encrypted = false
    @chunks = nil
    @attachments = []
    @thread_id = opts[:tid]
    @id = nil

    ## we need to initialize this. see comments in parse_header as to
    ## why.
    @refs = []

    @filename = opts[:filename]
    if opts[:json]
      load_from_json! opts[:json] # notmuch json format
    elsif opts[:id]
      @id = opts[:id].sub(/^</, '').sub(/>$/, '')
      load_from_notmuch! # notmuch id -> file, load from file, slow
    elsif opts[:header]
      parse_header(opts[:header])
    end
    raise 'filename is required' if @filename.nil?
  end

  def load_from_json! mjson
    @id = mjson['id']
    @labels |= Set.new((mjson['tags'] || []).map(&:to_sym))
    @subj = mjson['headers']['Subject']
    @filename = mjson['filename'][0]
    @date_relative = mjson['date_relative']
    @from = Person.from_address(mjson['headers']['From'])
    @to = Person.from_address_list(mjson['headers']['To'])
    @cc = Person.from_address_list(mjson['headers']['Cc'])
    @bcc = Person.from_address_list(mjson['headers']['Bcc'])
    @date = Time.parse(mjson['headers']['Date'])
  end

  def decode_header_field v
    return unless v
    return v unless v.is_a? String
    return unless v.size < MAX_HEADER_VALUE_SIZE # avoid regex blowup on spam
    d = v.dup
    d = d.transcode($encoding, 'ASCII')
    Rfc2047.decode_to $encoding, d
  end

  def parse_header encoded_header
    header = SavingHash.new { |k| decode_header_field encoded_header[k] }

    @id ||= ''
    @raw_mid = header["message-id"]
    if @raw_mid
      mid = @raw_mid =~ /<(.+?)>/ ? $1 : @raw_mid
      @id = mid
    end
    if (not @id.start_with?("notmuch-")) && ((not @id.include? '@') || @id.length < 6)
      @id = "sup-faked-" + Digest::MD5.hexdigest(raw_header)
      #from = header["from"]
      #debug "faking non-existent message-id for message from #{from}: #{id}"
    end

    @from = Person.from_address(
      header["reply-to"] || header["from"] ||
      "Sup Auto-generated Fake Sender <sup@fake.sender.example.com>"
    )

    @orig_from = header["x-original-from"] || "?"

    @date = case(date = header["date"])
    when Time
      date
    when String
      begin
        Time.parse date
      rescue ArgumentError => e
        #debug "faking mangled date header for #{@id} (orig #{header['date'].inspect} gave error: #{e.message})"
        Time.now
      end
    else
      #debug "faking non-existent date header for #{@id}"
      Time.now
    end

    subj = header["subject"]
    subj = subj ? subj.fix_encoding! : nil
    @subj = subj ? subj.gsub(/\s+/, " ").gsub(/\s+$/, "") : DEFAULT_SUBJECT
    @to = Person.from_address_list header["to"]
    @cc = Person.from_address_list header["cc"]
    @bcc = Person.from_address_list header["bcc"]

    ## before loading our full header from the source, we can actually
    ## have some extra refs set by the UI. (this happens when the user
    ## joins threads manually). so we will merge the current refs values
    ## in here.
    refs = (header["references"] || "").scan(/<(.+?)>/).map { |x| x.first }
    @refs = (@refs + refs).uniq
    @replytos = (header["in-reply-to"] || "").scan(/<(.+?)>/).map { |x| x.first }

    @replyto = Person.from_address header["reply-to"]
    @list_address = if header["list-post"]
      address = if header["list-post"] =~ /mailto:(.*?)[>\s$]/
        $1
      elsif header["list-post"] =~ /@/
        header["list-post"] # just try the whole fucking thing
      end
      address && Person.from_address(address)
    elsif header["x-mailing-list"]
      Person.from_address header["x-mailing-list"]
    end

    @recipient_email = header["envelope-to"] || header["x-original-to"] || header["delivered-to"]
    @source_marked_read = header["status"] == "RO"
    @list_subscribe = header["list-subscribe"]
    @list_unsubscribe = header["list-unsubscribe"]
  end

  def thread_id
    return nil if @id.nil?
    @thread_id ||= Notmuch.thread_id_from_message_id @id
  end

  def load_from_notmuch!
    mid = @id
    if not @filename
      @filename = Notmuch.filenames_from_message_id(mid)[0]
      load_from_source!
    end
    @labels = Set.new(Notmuch.tags_from_message_id(mid).map(&:to_sym))
  end

  def add_ref ref
    @refs << ref
  end

  def remove_ref ref
    @refs.delete ref
  end

  attr_reader :snippet
  def is_list_message?; !@list_address.nil?; end
  def is_draft?; @labels.member? :draft; end
  def draft_filename
    raise "not a draft" unless is_draft?
    @filename
  end

  def clear_dirty_labels
    @dirty_labels = false
  end

  def clear_dirty
    @dirty = @dirty_labels = false
  end

  def has_label? t; @labels.member? t; end
  def add_label l
    l = l.to_sym
    return if @labels.member? l
    @labels << l
    @dirty_labels = true
  end
  def remove_label l
    l = l.to_sym
    return unless @labels.member? l
    @labels.delete l
    @dirty_labels = true
  end

  def recipients
    @to + @cc + @bcc
  end

  def labels= l
    raise ArgumentError, "not a set" unless l.is_a?(Set)
    raise ArgumentError, "not a set of labels" unless l.all? { |ll| ll.is_a?(Symbol) }
    return if @labels == l
    @labels = l
    @dirty_labels = true
  end

  def chunks
    load_from_source!
    @chunks
  end

  ## this is called when the message body needs to actually be loaded.
  def load_from_source!
    return unless @filename # should we just fail here?
    @chunks ||=
      begin
        ## we need to re-read the header because it contains information
        ## that we don't store in the index. actually i think it's just
        ## the mailing list address (if any), so this is kinda overkill.
        ## i could just store that in the index, but i think there might
        ## be other things like that in the future, and i'd rather not
        ## bloat the index.
        ## actually, it's also the differentiation between to/cc/bcc,
        ## so i will keep this.
        rmsg = File.open(@filename, 'rb') {|f| RMail::Parser.read f}
        parse_header rmsg.header
        message_to_chunks rmsg
      rescue SocketError, RMail::EncodingUnsupportedError => e
        warn_with_location "problem reading message #{id}"

        [Chunk::Text.new(error_message.split("\n"))]

      rescue Exception => e
        warn_with_location "problem reading message #{id}"
        raise e
      end
  end

  def raw_message_id
    # if @raw_mid (which is accurate) is not available, guess it from the index id @id
    @raw_mid || "<#{@id}>"
  end

  def patch
    # expire cache
    @patch = nil if PatchworkDatabase::updated_at.to_i > @patch_updated_at.to_i
    # patchwork patch
    @patch ||= \
      begin
        @patch_updated_at = Time.now.to_i
        PatchworkDatabase::Patch.where(msgid: raw_message_id).includes(:delegate, :state).first
      end
  end

  def reload_from_source!
    @chunks = nil
    load_from_source!
  end


  def error_message
    <<EOS
#@snippet...

***********************************************************************
 An error occurred while loading this message.
***********************************************************************
EOS
  end

  def check_filename
    unless File.exists?(@filename)
      @filename = Notmuch.filenames_from_message_id(@id)[0]
    end
  end

  def raw_header
    check_filename
    ret = ""
    File.open(@filename) do |f|
      until f.eof? || (l = f.gets) =~ /^$/
        ret += l
      end
    end
    ret
  end

  def raw_message
    check_filename
    File.open(@filename) { |f| f.read }
  end

  def each_raw_message_line &b
    File.open(@filename) do |f|
      until f.eof?
        yield f.gets
      end
    end
  end

  def sync_back
    sync_back_labels
  end

  def sync_back_labels
    self.class.sync_back_labels [self]
  end

  def self.sync_back_labels messages
    dirtymessages = [*messages].select{|m|m&&m.dirty_labels?}
    Notmuch::tag_batch(dirtymessages.map{|m| ["id:#{m.id}", m.labels]})
    dirtymessages.each(&:clear_dirty_labels)
  end

  def quotable_body_lines
    chunks.find_all { |c| c.quotable? }.map { |c| c.lines }.flatten
  end

  def quotable_header_lines
    ["From: #{@from.full_address}"] +
      (@to.empty? ? [] : ["To: " + @to.map { |p| p.full_address }.join(", ")]) +
      (@cc.empty? ? [] : ["Cc: " + @cc.map { |p| p.full_address }.join(", ")]) +
      (@bcc.empty? ? [] : ["Bcc: " + @bcc.map { |p| p.full_address }.join(", ")]) +
      ["Date: #{@date.rfc822}",
       "Subject: #{@subj}"]
  end

  def self.parse_raw_email_header f
    header = {}
    last = nil

    while(line = f.gets)
      case line
      ## these three can occur multiple times, and we want the first one
      when /^(Delivered-To|X-Original-To|Envelope-To):\s*(.*?)\s*$/i; header[last = $1.downcase] ||= $2
      ## regular header: overwrite (not that we should see more than one)
      ## TODO: figure out whether just using the first occurrence changes
      ## anything (which would simplify the logic slightly)
      when /^([^:\s]+):\s*(.*?)\s*$/i; header[last = $1.downcase] = $2
      when /^\r*$/; break # blank line signifies end of header
      else
        if last
          header[last] << " " unless header[last].empty?
          header[last] << line.strip
        end
      end
    end

    %w(subject from to cc bcc).each do |k|
      v = header[k] or next
      next unless Rfc2047.is_encoded? v
      header[k] = begin
        Rfc2047.decode_to $encoding, v
      rescue Errno::EINVAL, Iconv::InvalidEncoding, Iconv::IllegalSequence => e
        #debug "warning: error decoding RFC 2047 header (#{e.class.name}): #{e.message}"
        v
      end
    end
    header
  end

private

  ## here's where we handle decoding mime attachments. unfortunately
  ## but unsurprisingly, the world of mime attachments is a bit of a
  ## mess. as an empiricist, i'm basing the following behavior on
  ## observed mail rather than on interpretations of rfcs, so probably
  ## this will have to be tweaked.
  ##
  ## the general behavior i want is: ignore content-disposition, at
  ## least in so far as it suggests something being inline vs being an
  ## attachment. (because really, that should be the recipient's
  ## decision to make.) if a mime part is text/plain, OR if the user
  ## decoding hook converts it, then decode it and display it
  ## inline. for these decoded attachments, if it has associated
  ## filename, then make it collapsable and individually saveable;
  ## otherwise, treat it as regular body text.
  ##
  ## everything else is just an attachment and is not displayed
  ## inline.
  ##
  ## so, in contrast to mutt, the user is not exposed to the workings
  ## of the gruesome slaughterhouse and sausage factory that is a
  ## mime-encoded message, but need only see the delicious end
  ## product.

  def multipart_signed_to_chunks m
    if m.body.size != 2
      warn_with_location "multipart/signed with #{m.body.size} parts (expecting 2)"
      return
    end

    payload, signature = m.body
    if signature.multipart?
      warn_with_location "multipart/signed with payload multipart #{payload.multipart?} and signature multipart #{signature.multipart?}"
      return
    end

    ## this probably will never happen
    if payload.header.content_type && payload.header.content_type.downcase == "application/pgp-signature"
      warn_with_location "multipart/signed with payload content type #{payload.header.content_type}"
      return
    end

    if signature.header.content_type && signature.header.content_type.downcase != "application/pgp-signature"
      ## unknown signature type; just ignore.
      #warn "multipart/signed with signature content type #{signature.header.content_type}"
      return
    end

    [CryptoManager.verify(payload, signature), message_to_chunks(payload)].flatten.compact
  end

  def multipart_encrypted_to_chunks m
    if m.body.size != 2
      warn_with_location "multipart/encrypted with #{m.body.size} parts (expecting 2)"
      return
    end

    control, payload = m.body
    if control.multipart?
      warn_with_location "multipart/encrypted with control multipart #{control.multipart?} and payload multipart #{payload.multipart?}"
      return
    end

    if payload.header.content_type && payload.header.content_type.downcase != "application/octet-stream"
      warn_with_location "multipart/encrypted with payload content type #{payload.header.content_type}"
      return
    end

    if control.header.content_type && control.header.content_type.downcase != "application/pgp-encrypted"
      warn_with_location "multipart/encrypted with control content type #{signature.header.content_type}"
      return
    end

    notice, sig, decryptedm = CryptoManager.decrypt payload
    if decryptedm # managed to decrypt
      children = message_to_chunks(decryptedm, true)
      [notice, sig].compact + children
    else
      [notice]
    end
  end

  ## takes a RMail::Message, breaks it into Chunk:: classes.
  def message_to_chunks m, encrypted=false, sibling_types=[]
    if m.multipart?
      chunks =
        case m.header.content_type.downcase
        when "multipart/signed"
          multipart_signed_to_chunks m
        when "multipart/encrypted"
          multipart_encrypted_to_chunks m
        end

      unless chunks
        sibling_types = m.body.map { |p| p.header.content_type }
        chunks = m.body.map { |p| message_to_chunks p, encrypted, sibling_types }.flatten.compact
      end

      chunks
    elsif m.header.content_type && m.header.content_type.downcase == "message/rfc822"
      encoding = m.header["Content-Transfer-Encoding"]
      if m.body
        body =
        case encoding
        when "base64"
          m.body.unpack("m")[0]
        when "quoted-printable"
          m.body.unpack("M")[0]
        when "7bit", "8bit", nil
          m.body
        else
          raise RMail::EncodingUnsupportedError, encoding.inspect
        end
        body = body.normalize_whitespace
        payload = RMail::Parser.read(body)
        from = payload.header.from.first ? payload.header.from.first.format : ""
        to = payload.header.to.map { |p| p.format }.join(", ")
        cc = payload.header.cc.map { |p| p.format }.join(", ")
        subj = decode_header_field(payload.header.subject) || DEFAULT_SUBJECT
        subj = Message.normalize_subj(subj.gsub(/\s+/, " ").gsub(/\s+$/, ""))
        msgdate = payload.header.date
        from_person = from ? Person.from_address(decode_header_field(from)) : nil
        to_people = to ? Person.from_address_list(decode_header_field(to)) : nil
        cc_people = cc ? Person.from_address_list(decode_header_field(cc)) : nil
        [Chunk::EnclosedMessage.new(from_person, to_people, cc_people, msgdate, subj)] + message_to_chunks(payload, encrypted)
      else
        debug "no body for message/rfc822 enclosure; skipping"
        []
      end
    elsif m.header.content_type && m.header.content_type.downcase == "application/pgp" && m.body
      ## apparently some versions of Thunderbird generate encryped email that
      ## does not follow RFC3156, e.g. messages with X-Enigmail-Version: 0.95.0
      ## they have no MIME multipart and just set the body content type to
      ## application/pgp. this handles that.
      ##
      ## TODO 1: unduplicate code between here and
      ##         multipart_encrypted_to_chunks
      ## TODO 2: this only tries to decrypt. it cannot handle inline PGP
      notice, sig, decryptedm = CryptoManager.decrypt m.body
      if decryptedm # managed to decrypt
        children = message_to_chunks decryptedm, true
        [notice, sig].compact + children
      else
        ## try inline pgp signed
      	chunks = inline_gpg_to_chunks m.body, $encoding, (m.charset || $encoding)
        if chunks
          chunks
        else
          [notice]
        end
      end
    else
      filename =
        ## first, paw through the headers looking for a filename.
        ## RFC 2183 (Content-Disposition) specifies that disposition-parms are
        ## separated by ";". So, we match everything up to " and ; (if present).
        if m.header["Content-Disposition"] && m.header["Content-Disposition"] =~ /filename="?(.*?[^\\])("|;|\z)/m
          $1
        elsif m.header["Content-Type"] && m.header["Content-Type"] =~ /name="?(.*?[^\\])("|;|\z)/im
          $1

        ## haven't found one, but it's a non-text message. fake
        ## it.
        ##
        ## TODO: make this less lame.
        elsif m.header["Content-Type"] && m.header["Content-Type"] !~ /^text\/plain/i
          extension =
            case m.header["Content-Type"]
            when /text\/html/ then "html"
            when /image\/(.*)/ then $1
            end

          ["sup-attachment-#{Time.now.to_i}-#{rand 10000}", extension].join(".")
        end

      ## if there's a filename, we'll treat it as an attachment.
      if filename
        ## filename could be 2047 encoded
        filename = Rfc2047.decode_to $encoding, filename
        # add this to the attachments list if its not a generated html
        # attachment (should we allow images with generated names?).
        # Lowercase the filename because searches are easier that way
        @attachments.push filename.downcase unless filename =~ /^sup-attachment-/
        add_label :attachment unless filename =~ /^sup-attachment-/
        content_type = (m.header.content_type || "application/unknown").downcase # sometimes RubyMail gives us nil
        [Chunk::Attachment.new(content_type, filename, m, sibling_types)]

      ## otherwise, it's body text
      else
        ## Decode the body, charset conversion will follow either in
        ## inline_gpg_to_chunks (for inline GPG signed messages) or
        ## a few lines below (messages without inline GPG)
        body = m.body ? m.decode : ""

        ## Check for inline-PGP
        chunks = inline_gpg_to_chunks body, $encoding, (m.charset || $encoding)
        return chunks if chunks

        if m.body
          ## if there's no charset, use the current encoding as the charset.
          ## this ensures that the body is normalized to avoid non-displayable
          ## characters
          body = m.decode.transcode($encoding, m.charset)
        else
          body = ""
        end

        text_to_chunks(body.normalize_whitespace.split("\n"), encrypted)
      end
    end
  end

  ## looks for gpg signed (but not encrypted) inline  messages inside the
  ## message body (there is no extra header for inline GPG) or for encrypted
  ## (and possible signed) inline GPG messages
  def inline_gpg_to_chunks body, encoding_to, encoding_from
    lines = body.split("\n")

    # First case: Message is enclosed between
    #
    # -----BEGIN PGP SIGNED MESSAGE-----
    # and
    # -----END PGP SIGNED MESSAGE-----
    #
    # In some cases, END PGP SIGNED MESSAGE doesn't appear
    # (and may leave strange -----BEGIN PGP SIGNATURE----- ?)
    gpg = lines.between(GPG_SIGNED_START, GPG_SIGNED_END)
    # between does not check if GPG_END actually exists
    # Reference: http://permalink.gmane.org/gmane.mail.sup.devel/641
    if !gpg.empty?
      msg = RMail::Message.new
      msg.body = gpg.join("\n")

      body = body.transcode(encoding_to, encoding_from)
      lines = body.split("\n")
      sig = lines.between(GPG_SIGNED_START, GPG_SIG_START)
      startidx = lines.index(GPG_SIGNED_START)
      endidx = lines.index(GPG_SIG_END)
      before = startidx != 0 ? lines[0 .. startidx-1] : []
      after = endidx ? lines[endidx+1 .. lines.size] : []

      # sig contains BEGIN PGP SIGNED MESSAGE and END PGP SIGNATURE, so
      # we ditch them. sig may also contain the hash used by PGP (with a
      # newline), so we also skip them
      sig_start = sig[1].match(/^Hash:/) ? 3 : 1
      sig_end = sig.size-2
      payload = RMail::Message.new
      payload.body = sig[sig_start, sig_end].join("\n")
      return [text_to_chunks(before, false),
              CryptoManager.verify(nil, msg, false),
              message_to_chunks(payload),
              text_to_chunks(after, false)].flatten.compact
    end

    # Second case: Message is encrypted

    gpg = lines.between(GPG_START, GPG_END)
    # between does not check if GPG_END actually exists
    if !gpg.empty? && !lines.index(GPG_END).nil?
      msg = RMail::Message.new
      msg.body = gpg.join("\n")

      startidx = lines.index(GPG_START)
      before = startidx != 0 ? lines[0 .. startidx-1] : []
      after = lines[lines.index(GPG_END)+1 .. lines.size]

      notice, sig, decryptedm = CryptoManager.decrypt msg, true
      chunks = if decryptedm # managed to decrypt
        children = message_to_chunks(decryptedm, true)
        [notice, sig].compact + children
      else
        [notice]
      end
      return [text_to_chunks(before, false),
              chunks,
              text_to_chunks(after, false)].flatten.compact
    end
  end

  HookManager.register "text-filter", <<EOS
Filter the content of a text chunk before displaying it. It also allows
customization about whether the chunk is expanded or collapsed initially.

The filter is useful to remove boring signatures, or mitigate malicious
behavior that some email providers rewrite URLs on the fly. It can also
be used to expand short quote chunks automatically.

Variables:
          lines: an array of strings, the content of the chunk
          type: One of :text, :quote, :block_quote :sig

Return value:
  An array of strings, which will be used as the content of the chunk.
  If the array is empty, the chunk will not be added.
  Or, a hash {lines: v1, expand: v2}, where v1 is described above and
  v2 is a boolean value deciding whether the chunk is expended initially.
  Or, nil if nothing needs change.
EOS

  def append_chunk chunks, orig_lines, type
    opts = HookManager.run("text-filter", :lines => orig_lines, :type => type)
    lines = orig_lines
    expand = nil
    case opts
    when Array
      lines = opts
    when Hash
      lines = opts[:lines] || orig_lines
      expand = opts[:expand]
    end
    return if lines.empty?
    chunk = case type
            when :text
              Chunk::Text.new(lines)
            when :quote, :block_quote
              Chunk::Quote.new(lines)
            when :sig
              Chunk::Signature.new(lines)
            else
              raise "unknown chunk type: #{type}"
            end
    case expand
    when true
      def chunk.initial_state; :open; end
    when false
      def chunk.initial_state; :closed; end
    end
    chunks << chunk
  end

  ## parse the lines of text into chunk objects.  the heuristics here
  ## need tweaking in some nice manner. TODO: move these heuristics
  ## into the classes themselves.
  def text_to_chunks lines, encrypted
    state = :text # one of :text, :quote, or :sig
    chunks = []
    chunk_lines = []
    nextline_index = -1

    lines.each_with_index do |line, i|
      if i >= nextline_index
        # look for next nonblank line only when needed to avoid O(n²)
        # behavior on sequences of blank lines
        if nextline_index = lines[(i+1)..-1].index { |l| l !~ /^\s*$/ } # skip blank lines
          nextline_index += i + 1
          nextline = lines[nextline_index]
        else
          nextline_index = lines.length
          nextline = nil
        end
      end

      case state
      when :text
        newstate = nil

        ## the following /:$/ followed by /\w/ is an attempt to detect the
        ## start of a quote. this is split into two regexen because the
        ## original regex /\w.*:$/ had very poor behavior on long lines
        ## like ":a:a:a:a:a" that occurred in certain emails.
        if line =~ QUOTE_PATTERN || (line =~ /:$/ && line =~ /\w/ && nextline =~ QUOTE_PATTERN)
          newstate = :quote
        elsif line =~ SIG_PATTERN && (lines.length - i) < MAX_SIG_DISTANCE && !lines[(i+1)..-1].index { |l| l =~ /^-- $/ }
          newstate = :sig
        elsif line =~ BLOCK_QUOTE_PATTERN
          newstate = :block_quote
        end

        if newstate
          append_chunk chunks, chunk_lines, state
          chunk_lines = [line]
          state = newstate
        else
          chunk_lines << line
        end

      when :quote
        newstate = nil

        if line =~ QUOTE_PATTERN || (line =~ /^\s*$/ && nextline =~ QUOTE_PATTERN)
          chunk_lines << line
        elsif line =~ SIG_PATTERN && (lines.length - i) < MAX_SIG_DISTANCE
          newstate = :sig
        else
          newstate = :text
        end

        if newstate
          append_chunk chunks, chunk_lines, state
          chunk_lines = [line]
          state = newstate
        end

      when :block_quote, :sig
        chunk_lines << line
      end

      if !@have_snippet && state == :text && (@snippet.nil? || @snippet.length < SNIPPET_LEN) && line !~ /[=\*#_-]{3,}/ && line !~ /^\s*$/
        @snippet ||= ""
        @snippet += " " unless @snippet.empty?
        @snippet += line.gsub(/^\s+/, "").gsub(/[\r\n]/, "").gsub(/\s+/, " ")
        oldlen = @snippet.length
        @snippet = @snippet[0 ... SNIPPET_LEN].chomp
        @snippet += "..." if @snippet.length < oldlen
        @snippet_contains_encrypted_content = true if encrypted
      end
    end

    ## final object
    append_chunk chunks, chunk_lines, state
    chunks
  end

  def warn_with_location msg
    warn msg
    warn "Message is in #{@filename}"
  end
end

end
