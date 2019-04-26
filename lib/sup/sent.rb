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
      new_fn = new_maildir_basefn + ':2,S'
      Dir.chdir(@dir) do |d|
	tmp_path = File.join(@dir, 'tmp', new_fn)
	new_path = File.join(@dir, 'new', new_fn)
	begin
	  sleep 2 if File.stat(tmp_path)

	  File.stat(tmp_path)
	rescue Errno::ENOENT #this is what we want.
	  begin
	    File.open(tmp_path, 'wb') do |f|
	      yield f #provide a writable interface for the caller
	      f.fsync
	    end

	    File.safe_link tmp_path, new_path
	    stored = true
	  ensure
	    File.unlink tmp_path if File.exist? tmp_path
	  end
	end #rescue Errno...
      end #Dir.chdir
      PollManager.poll
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
