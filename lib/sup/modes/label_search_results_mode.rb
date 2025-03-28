module Redwood

class LabelSearchResultsMode < ThreadIndexMode
  def initialize labels
    @labels = labels
    opts = { :labels => @labels }
    opts[:load_deleted] = true if labels.include? :deleted
    opts[:load_spam] = true if labels.include? :spam
    super [], opts
  end

  register_keymap do |k|
    k.add :refine_search, "Refine search", '|'
  end

  def refine_search
    label_query = @labels.size > 1 ? "(#{@labels.join('||')})" : @labels.first
    query = BufferManager.ask :search, "refine query: ", "+label:#{label_query} "
    return unless query && query !~ /^\s*$/
    SearchResultsMode.spawn_from_query query
  end

  def self.spawn_nicely label
    label = LabelManager.label_for(label) unless label.is_a?(Symbol)
    case label
    when nil
    when :inbox
      BufferManager.raise_to_front InboxMode.instance.buffer
    else
      b, new = BufferManager.spawn_unless_exists("All threads with label '#{label}'") { LabelSearchResultsMode.new [label] }
      b.mode.load_threads :num => b.content_height if new
    end
  end
end

end
