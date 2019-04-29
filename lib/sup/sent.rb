module Redwood

class SentManager
  include Redwood::Singleton

  def initialize folder
    @folder = folder
  end

  def write_sent_message date, from_email, &block
    stored = false
    ::Thread.new do
      debug "store the sent message"
      cmd = "notmuch insert "
      if @folder
	cmd << "--create-folder --folder=#{@folder}"
      end
      pipe = IO.popen(cmd, "w:UTF-8")
      if pipe
	yield pipe
	pipe.close
	stored = true
        Notmuch.poll
        PollManager.poll
      else
	debug "Unable to pipe to #{cmd}"
      end
    end #Thread.new
    stored
  end

end # class

end # module
