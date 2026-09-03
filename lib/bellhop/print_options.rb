# frozen_string_literal: true

module Bellhop
  # Print options, checked at the call site. Anything knowable without an
  # agent is refused here: an unknown option, a value outside its range, a
  # malformed page range, an option that does not apply to the job's format.
  # Whether a particular printer can honour an option is the agent's to
  # decide, and comes back as a failed ack with an `error_code`.
  #
  # `options` is a closed set, the one place in the protocol where an unknown
  # field fails instead of being ignored: ignoring one would print something
  # other than what was asked for and report success.
  module PrintOptions
    APPLIES = {
      "copies"  => %w[zpl raw pdf gif],
      "duplex"  => %w[pdf],
      "paper"   => %w[pdf gif],
      "bin"     => %w[pdf gif],
      "dpi"     => %w[pdf gif],
      "color"   => %w[pdf gif],
      "pages"   => %w[pdf],
      "rotate"  => %w[pdf gif],
      "fit"     => %w[pdf gif],
      "collate" => %w[pdf],
      "nup"     => %w[pdf]
    }.freeze

    DUPLEX = %w[one-sided long-edge short-edge].freeze
    ROTATE = [ 0, 90, 180, 270 ].freeze
    NUP    = [ 1, 2, 4, 6, 9, 16 ].freeze

    # The grammar for `pages`. Ordering and overlap are checked in `pages?`.
    PAGES = /\A[1-9][0-9]*(-[1-9][0-9]*)?(,[1-9][0-9]*(-[1-9][0-9]*)?)*\z/

    module_function

    # Returns the options string-keyed and ready for the wire, or raises an
    # AgentError naming what is wrong.
    def validate!(options, format:, agent: nil)
      raise ArgumentError, "`options` must be a Hash, got #{options.class}." unless options.is_a?(Hash)

      options.each_with_object({}) do |(key, value), normalized|
        name    = key.to_s
        formats = APPLIES[name]

        unless formats
          raise AgentError.new(
            "Unknown print option `#{name}`. Version 1 defines: #{APPLIES.keys.join(', ')}.",
            agent: agent
          )
        end

        unless formats.include?(format)
          raise AgentError.new(
            "The `#{name}` option does not apply to #{format}. It applies to: #{formats.join(', ')}.",
            agent: agent
          )
        end

        unless valid?(name, value)
          raise AgentError.new("#{complaint(name)}, got #{value.inspect}.", agent: agent)
        end

        normalized[name] = value
      end
    end

    def valid?(name, value)
      case name
      when "copies"                  then value.is_a?(Integer) && value.between?(1, 100)
      when "duplex"                  then DUPLEX.include?(value)
      when "paper", "bin"            then value.is_a?(String) && !value.empty?
      when "dpi"                     then value.is_a?(Integer) && value.positive?
      when "color", "fit", "collate" then value == true || value == false
      when "pages"                   then pages?(value)
      when "rotate"                  then value.is_a?(Integer) && ROTATE.include?(value)
      when "nup"                     then value.is_a?(Integer) && NUP.include?(value)
      end
    end

    def complaint(name)
      case name
      when "copies"                  then "`copies` must be an integer from 1 to 100"
      when "duplex"                  then %(`duplex` must be "one-sided", "long-edge", or "short-edge")
      when "paper", "bin"            then "`#{name}` must be one of the strings the printer reported"
      when "dpi"                     then "`dpi` must be a positive integer"
      when "color", "fit", "collate" then "`#{name}` must be true or false"
      when "pages"                   then %(`pages` must be ascending, non-overlapping terms like "1-4,7,9-12", with no spaces)
      when "rotate"                  then "`rotate` must be 0, 90, 180, or 270, degrees clockwise"
      when "nup"                     then "`nup` must be 1, 2, 4, 6, 9, or 16 pages per sheet"
      end
    end

    # "1-4,7" is valid; "7,1-4", "4-1", "1-4,4", and "1-4, 7" are not.
    def pages?(value)
      return false unless value.is_a?(String) && value.match?(PAGES)

      ceiling = 0
      value.split(",").all? do |term|
        first, last = term.split("-").map { |number| Integer(number) }
        last ||= first
        ordered = first > ceiling && first <= last
        ceiling = last
        ordered
      end
    end
  end
end
