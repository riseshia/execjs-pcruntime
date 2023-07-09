# frozen_string_literal: true

# XXX: Seem to useless require.
require 'execjs/pcruntime/version'
require 'execjs/pcruntime/context_process_runtime'
# XXX: Prefer dependency be top of require statements to make clear dependency,
#      but also preventing load error.
require 'execjs/runtimes'

module ExecJS
  # extends ExecJS::Runtimes
  module Runtimes
    # XXX: (maybe) How about using same interface with others bundled in execjs?
    #      e.g. https://github.com/rails/execjs/blob/f49db2167accbc1b8ec117e12dd397ed8a5a2534/lib/execjs/runtimes.rb#L21-L26
    PCRuntime = PCRuntime::ContextProcessRuntime.new(
      'Node.js (V8) Process as Context',
      %w[nodejs node]
    )

    runtimes.unshift(PCRuntime)
  end
end
