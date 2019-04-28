module Redwood

class SentManager
  include Redwood::Singleton

  def initialize source_uri
    if source_uri =~ /^maildir:(\/\/)?(.*)/
      @dir = $2
      unless File.directory?(@dir)
        raise ArgumentError, "No such directory #{@dir}"
      end
    else
      raise ArgumentError, "#{source_uri} not a maildir URI; check :sent_source in ~/.sup/config.yaml"
    end
    @hostname = Socket.gethostname
  end

  def write_sent_message date, from_email, &block
    stored = false
    ::Thread.new do
      debug "store the sent message"
      pipe = IO.popen("notmuch insert --create-folder --folder=sent", "w:UTF-8")
      if pipe
	yield pipe
	pipe.close
	stored = true
        Notmuch.poll
        PollManager.poll
      else
	debug "Unable to store message!"
      end
    end #Thread.new
    stored
  end

private

  def new_maildir_basefn
    Kernel::srand()
    "#{Time.now.to_i.to_s}.#{$$}#{Kernel.rand(1000000)}.#{@hostname}"
  end

end # class

end # module
