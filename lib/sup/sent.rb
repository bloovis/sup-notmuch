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
      stored = Notmuch.insert(@folder, &block)
    end #Thread.new
    stored
  end

end # class

end # module
