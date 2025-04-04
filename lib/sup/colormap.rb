module Ncurses
  COLOR_DEFAULT = -1

  NUM_COLORS = `tput colors`.to_i
  MAX_PAIRS = `tput pairs`.to_i

  def self.color! name, value
    const_set "COLOR_#{name.to_s.upcase}", value
  end

  ## numeric colors
  Ncurses::NUM_COLORS.times { |x| color! x, x }

  if Ncurses::NUM_COLORS == 256
    ## xterm 6x6x6 color cube
    6.times { |x| 6.times { |y| 6.times { |z| color! "c#{x}#{y}#{z}", 16 + z + 6*y + 36*x } } }

    ## xterm 24-shade grayscale
    24.times { |x| color! "g#{x}", (16+6*6*6) + x }
  elsif Ncurses::NUM_COLORS == -1
    ## Terminal emulator doesn't appear to support colors
    fail "sup must be run in a terminal with color support, please check your TERM variable."
  end
end

module Redwood

class Colormap
  @@instance = nil

  DEFAULT_COLORS = {
    :text => { :fg => "white", :bg => "black" },
    :status => { :fg => "white", :bg => "blue", :attrs => ["bold"] },
    :status_inactive => { :fg => "black", :bg => "white" },
    :index_old => { :fg => "white", :bg => "default" },
    :index_new => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :index_starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :index_draft => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :labellist_old => { :fg => "white", :bg => "default" },
    :labellist_new => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :twiddle => { :fg => "blue", :bg => "default" },
    :label => { :fg => "yellow", :bg => "default" },
    :message_patina => { :fg => "black", :bg => "green" },
    :alternate_patina => { :fg => "black", :bg => "blue" },
    :missing_message => { :fg => "black", :bg => "red" },
    :attachment => { :fg => "cyan", :bg => "default" },
    :cryptosig_valid => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :cryptosig_valid_untrusted => { :fg => "yellow", :bg => "blue", :attrs => ["bold"] },
    :cryptosig_unknown => { :fg => "cyan", :bg => "default" },
    :cryptosig_invalid => { :fg => "yellow", :bg => "red", :attrs => ["bold"] },
    :generic_notice_patina => { :fg => "cyan", :bg => "default" },
    :quote_patina => { :fg => "yellow", :bg => "default" },
    :sig_patina => { :fg => "yellow", :bg => "default" },
    :quote => { :fg => "yellow", :bg => "default" },
    :sig => { :fg => "yellow", :bg => "default" },
    :to_me => { :fg => "green", :bg => "default" },
    :with_attachment => { :fg => "green", :bg => "default" },
    :starred => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :starred_patina => { :fg => "yellow", :bg => "green", :attrs => ["bold"] },
    :alternate_starred_patina => { :fg => "yellow", :bg => "blue", :attrs => ["bold"] },
    :snippet => { :fg => "cyan", :bg => "default" },
    :option => { :fg => "white", :bg => "default" },
    :tagged => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :draft_notification => { :fg => "red", :bg => "default", :attrs => ["bold"] },
    :completion_character => { :fg => "white", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_selected => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :horizontal_selector_unselected => { :fg => "cyan", :bg => "default" },
    :search_highlight => { :fg => "black", :bg => "yellow", :attrs => ["bold"] },
    :system_buf => { :fg => "blue", :bg => "default" },
    :regular_buf => { :fg => "white", :bg => "default" },
    :modified_buffer => { :fg => "yellow", :bg => "default", :attrs => ["bold"] },
    :date => { :fg => "white", :bg => "default"},
    :size_widget => { :fg => "white", :bg => "default"},
    :patchwork_accepted => { :fg => "green", :bg => "default" },
    :patchwork_rejected => { :fg => "red", :bg => "default" },
    :patchwork_queuing => { :fg => "blue", :bg => "default" },
    :patchwork_unrelated => { :fg => "default", :bg => "default" },
    :editing_notification => { :fg => "white", :bg => "magenta", :attrs => ["bold"] },
    :editing_frozen_text => { :fg => "default", :bg => "default", :attrs => ["dim"] },
  }

  def initialize
    raise "only one instance can be created" if @@instance
    @@instance = self
    @color_pairs = {[Ncurses::COLOR_WHITE, Ncurses::COLOR_BLACK] => 0}
    @users = []
    @next_id = 0
    reset
    yield self if block_given?
  end

  def reset
    @entries = {}
    @highlights = { :none => highlight_sym(:none)}
    @entries[highlight_sym(:none)] = highlight_for(Ncurses::COLOR_WHITE,
                                                   Ncurses::COLOR_BLACK,
                                                   []) + [nil]
  end

  def add sym, fg, bg, attr=nil, highlight=nil
    raise ArgumentError, "color for #{sym} already defined" if @entries.member? sym
    raise ArgumentError, "color '#{fg}' unknown" unless (-1...Ncurses::NUM_COLORS).include? fg
    raise ArgumentError, "color '#{bg}' unknown" unless (-1...Ncurses::NUM_COLORS).include? bg
    attrs = [attr].flatten.compact

    @entries[sym] = [fg, bg, attrs, nil]

    if not highlight
      # create highlight on demand
      highlight = highlight_sym(sym)
      highlight_schema = highlight_for(fg, bg, attrs)
      @entries[highlight] = highlight_schema + [nil]

      # create "inactive" for "highlight"s automatically
      inactive_schema = inactive_for(*highlight_schema)
      @entries["#{highlight}_inactive".to_sym] = inactive_schema + [nil]
    end

    @highlights[sym] = highlight
  end

  def highlight_sym sym
    "#{sym}_highlight".intern
  end

  def highlight_for fg, bg, attrs
    hfg =
      case fg
      when Ncurses::COLOR_BLUE
        Ncurses::COLOR_WHITE
      when Ncurses::COLOR_YELLOW, Ncurses::COLOR_GREEN
        fg
      else
        Ncurses::COLOR_BLACK
      end

    hbg =
      case bg
      when Ncurses::COLOR_CYAN
        Ncurses::COLOR_YELLOW
      when Ncurses::COLOR_YELLOW
        Ncurses::COLOR_BLUE
      else
        Ncurses::COLOR_CYAN
      end

    hattrs =
      if fg == Ncurses::COLOR_WHITE && attrs.include?(Ncurses::A_BOLD)
        attrs
      elsif hfg == Ncurses::COLOR_BLACK
        attrs - [Ncurses::A_BOLD]
      else
        attrs | [Ncurses::A_BOLD]
      end
    [hfg, hbg, hattrs]
  end

  def inactive_for fg, bg, attrs
    ifg = Ncurses::COLOR_BLACK
    ibg = Ncurses::COLOR_WHITE
    [ifg, ibg, attrs]
  end

  def color_for sym, highlight=false, inactive=true
    sym = @highlights[sym] if highlight
    if inactive && @entries.key?("#{sym}_inactive".to_sym)
      sym = "#{sym}_inactive".to_sym
    end
    return Ncurses::COLOR_BLACK if sym == :none
    raise ArgumentError, "undefined color #{sym}" unless @entries.member? sym

    ## if this color is cached, return it
    fg, bg, attrs, color = @entries[sym]
    return color if color

    if(cp = @color_pairs[[fg, bg]])
      ## nothing
    else ## need to get a new colorpair
      @next_id = (@next_id + 1) % Ncurses::MAX_PAIRS
      @next_id += 1 if @next_id == 0 # 0 is always white on black
      id = @next_id
      # debug "colormap: for color #{sym}, using id #{id} -> #{fg}, #{bg}"
      Ncurses.init_pair id, fg, bg or raise ArgumentError,
        "couldn't initialize curses color pair #{fg}, #{bg} (key #{id})"

      cp = @color_pairs[[fg, bg]] = Ncurses.COLOR_PAIR(id)
      ## delete the old mapping, if it exists
      if @users[cp]
        @users[cp].each do |usym|
          warn "dropping color #{usym} (#{id})"
          @entries[usym][3] = nil
        end
        @users[cp] = []
      end
    end

    ## by now we have a color pair
    color = attrs.inject(cp) { |color, attr| color | attr }
    @entries[sym][3] = color # fill the cache
    (@users[cp] ||= []) << sym # record entry as a user of that color pair
    color
  end

  def sym_is_defined sym
      return sym if @entries.member? sym
  end

  ## Try to use the user defined colors, in case of an error fall back
  ## to the default ones.
  def populate_colormap
    user_colors = if File.exist? Redwood::COLOR_FN
      debug "loading user colors from #{Redwood::COLOR_FN}"
      Redwood::load_yaml_obj Redwood::COLOR_FN
    end

    ## Set attachment sybmol to sane default for existing colorschemes
    if user_colors and user_colors.has_key? :to_me
      user_colors[:with_attachment] = user_colors[:to_me] unless user_colors.has_key? :with_attachment
    end

    Colormap::DEFAULT_COLORS.merge(user_colors||{}).each_pair do |k, v|
      fg = begin
        Ncurses.const_get "COLOR_#{v[:fg].to_s.upcase}"
      rescue NameError
        warn "there is no color named \"#{v[:fg]}\""
        Ncurses::COLOR_GREEN
      end

      bg = begin
        Ncurses.const_get "COLOR_#{v[:bg].to_s.upcase}"
      rescue NameError
        warn "there is no color named \"#{v[:bg]}\""
        Ncurses::COLOR_RED
      end

      attrs = (v[:attrs]||[]).map do |a|
        begin
          Ncurses.const_get "A_#{a.upcase}"
        rescue NameError
          warn "there is no attribute named \"#{a}\", using fallback."
          nil
        end
      end.compact

      highlight_symbol = v[:highlight] ? :"#{v[:highlight]}_color" : nil

      symbol = (k.to_s + "_color").to_sym
      add symbol, fg, bg, attrs, highlight_symbol
    end
  end

  def self.instance; @@instance; end
  def self.method_missing meth, *a
    Colormap.new unless @@instance
    @@instance.send meth, *a
  end
  # Performance shortcut
  def self.color_for *a; @@instance.color_for *a; end
end

end
