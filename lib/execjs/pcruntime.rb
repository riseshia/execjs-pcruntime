# frozen_string_literal: true

require 'execjs/pcruntime/version'
require 'execjs/pcruntime/runtimes'
# XXX: I think this require statement have no effect to this gem.
#      Effective execjs require is done by each lib files such as "require 'execjs/runtime'".
#      We have 2 choices here, first is that moving up this require above L3,
#      or just remove this require and delegate dependency resolution to each module..
require 'execjs'
