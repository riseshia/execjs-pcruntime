# frozen_string_literal: true

require 'execjs/runtime'
require 'tmpdir'
require 'json'
require 'net/protocol'
require 'net/http'

module ExecJS
  module PCRuntime
    # override ExecJS::Runtime
    class ContextProcessRuntime < Runtime
      # override ExecJS::Runtime::Context
      class Context < Runtime::Context
        # @param [String] runtime Instance of ContextProcessRuntime
        # @param [String] source JavaScript source code that Runtime load at startup
        # @param [any] options
        def initialize(runtime, source = '', options = {})
          super(runtime, source, options)

          # @type [JSRuntimeHandle]
          @runtime = runtime.create_runtime_handle

          # load initial source to Context
          @runtime.evaluate(source.encode('UTF-8'))
        end

        # override ExecJS::Runtime::Context#eval
        # @param [String] source
        # @param [any] _options
        def eval(source, _options = {})
          return unless /\S/.match?(source)

          @runtime.evaluate("(#{source.encode('UTF-8')})")
        end

        # override ExecJS::Runtime::Context#exec
        # @param [String] source
        # @param [any] _options
        def exec(source, _options = {})
          @runtime.evaluate("(()=>{#{source.encode('UTF-8')}})()")
        end

        # override ExecJS::Runtime:Context#call
        # @param [String] identifier
        # @param [Array<_ToJson>] args
        def call(identifier, *args)
          @runtime.evaluate("(#{identifier}).apply(this, #{::JSON.generate(args)})")
        end
      end

      # Handle of JavaScript Runtime
      # launch Runtime by .new and finished on finalizer
      class JSRuntimeHandle
        # @param [Array<String>] binary Launch command for the node(or similar JavaScript Runtime) binary,
        #     such as ['node'], ['deno', 'run'].
        # @param [String] initial_source Path of .js Runtime loads at startup.
        def initialize(binary, initial_source)
          Dir::Tmpname.create 'execjs_pcruntime' do |path|
            # Dir::Tmpname.create rescues Errno::EEXIST and retry block
            # So, raise it if failed to create Process.
            @runtime_pid = create_process(path, *binary, initial_source) || raise(Errno::EEXIST)
            @socket_path = path
          end
          ObjectSpace.define_finalizer(self, self.class.finalizer(@runtime_pid))
        end

        # Evaluate JavaScript source code and return the result.
        # @param [String] source JavaScript source code
        # @return [object]
        def evaluate(source)
          post_request(@socket_path, '/eval', 'text/javascript', source)
        end

        # Create a procedure to kill the Process that has specified pid.
        # It used as the finalizer of JSRuntimeHandle.
        # @param [Integer] pid
        def self.finalizer(pid)
          proc do
            err = kill_process(pid)
            warn err.full_message unless err.nil?
          end
        end

        # Kill the Process that has specified pid.
        # If raised error then return it.
        # @param [Integer] pid
        # @return [StandardError, nil] return error iff an error is raised
        def self.kill_process(pid)
          Process.kill(:KILL, pid)
          nil
        rescue StandardError => e
          e
        end

        private

        # Attempt to execute the block several times, spacing out the attempts over a certain period.
        # @param [Integer] times maximum number of attempts
        # @yieldreturn [Boolean] true iff succeed execute
        # @return [Boolean] true if the block attempt is successful, false if the maximum number of attempts is reached
        def delayed_retries(times)
          while times.positive?
            return true if yield

            sleep 0.05
            times -= 1
          end
          false
        end

        # Launch JavaScript Runtime Process.
        # @param [String] socket_path path used for the UNIX domain socket
        #     it is passed at Runtime through the PORT environment variable
        # @param [Array<String>] command command to start the Runtime such as ['node', 'runner.js']
        # @return [Integer, nil] if the Process successfully launches, return its pid. if it fails return nil
        def create_process(socket_path, *command)
          pid = Process.spawn({ 'PORT' => socket_path }, *command)

          unless delayed_retries(20) { File.exist?(socket_path) }
            self.class.kill_process(pid)
            return nil
          end

          begin
            post_request(socket_path, '/')
          rescue StandardError
            self.class.kill_process(pid)
            return nil
          end
          pid
        end

        # Create a socket connected to the Process.
        # @return [Net::BufferedIO]
        def create_socket(socket_path)
          Net::BufferedIO.new(UNIXSocket.new(socket_path))
        end

        # Send request to JavaScript Runtime.
        # @param [String] socket_path path of the UNIX domain socket
        # @param [String] path Path on HTTP request such as '/eval'
        # @param [String, nil] content_type Content-type of body
        # @param [String, nil] body body of HTTP request
        # @return [object?]
        # There seems to be no particular meaning in dividing it any further and it's a simple sequential process
        # so suppressing lint errors.
        # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
        def post_request(socket_path, path, content_type = nil, body = nil)
          socket = create_socket socket_path

          # timeout occurred during the test
          socket.read_timeout *= 100
          socket.write_timeout *= 100

          request = Net::HTTP::Post.new(path)
          request['Connection'] = 'close'
          unless content_type.nil?
            request['Content-Type'] = content_type
            request.body = body
          end

          # Net::HTTPGenericRequest#exec
          # I'd rather not use it as it's marked for 'internal use only', but I can't find a good alternative.
          request.exec(socket, '1.1', path)

          # Adopting RuboCop's proposal changes the operation and causes an infinite loop
          # rubocop:disable Lint/Loop
          begin
            response = Net::HTTPResponse.read_new(socket)
          end while response.is_a?(Net::HTTPContinue)
          # rubocop:enable Lint/Loop
          response.reading_body(socket, request.response_body_permitted?) {}

          if response.code == '200'
            result = response.body
            ::JSON.parse(response.body, create_additions: false) if /\S/.match?(result)
          else
            message, stack = response.body.split "\0"
            error_class = /SyntaxError:/.match?(message) ? RuntimeError : ProgramError
            error = error_class.new(message)
            error.set_backtrace(stack)
            raise error
          end
        end
        # rubocop:enable Metrics/MethodLength,Metrics/AbcSize
      end

      attr_reader :name

      # @param [String] name name of Runtime
      # @param [Array<String>] command candidates for JavaScript Runtime commands such as ['deno run', 'node']
      # @param [String] runner_path path of the .js file to run in the Runtime
      def initialize(name, command, runner_path = File.expand_path('runner.js', __dir__), deprecated: false)
        super()
        @name = name
        @command = command
        @runner_path = runner_path
        @binary = nil
        @deprecated = deprecated
      end

      # override ExecJS::Runtime#available?
      def available?
        require 'json'
        binary ? true : false
      end

      # override ExecJS::Runtime#deprecated?
      def deprecated?
        @deprecated
      end

      # Launch JavaScript Runtime and return its handle.
      # @return [JSRuntimeHandle]
      def create_runtime_handle
        JSRuntimeHandle.new(binary, @runner_path)
      end

      private

      # Return the launch command for the JavaScript Runtime.
      # @return [Array<String>]
      def binary
        @binary ||= which(@command)
      end

      # Locate a executable file in the path.
      # @param [Array<String>] commands candidates for commands such as ['deno run', 'node']
      # @return [Array<String>] the absolute path of the command and command-line arguments
      #     e.g. ["/the/absolute/path/to/deno", "run"]
      def which(commands)
        commands.each do |command|
          command, *args = split_command_string command
          command = search_executable_path command
          return [command] + args unless command.nil?
        end
      end

      # Search for absolute path of the executable file from the command.
      # @param [String] command
      # @return [String, nil] the absolute path of the command, or nil if not found
      # It seems that further method splitting might actually make it harder to read, so suppressing
      # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      def search_executable_path(command)
        @extensions ||= ExecJS.windows? ? ENV['PATHEXT'].split(File::PATH_SEPARATOR) + [''] : ['']
        @path ||= ENV['PATH'].split(File::PATH_SEPARATOR) + ['']
        @path.each do |base_path|
          @extensions.each do |extension|
            executable_path = base_path == '' ? command + extension : File.join(base_path, command + extension)
            return executable_path if File.executable?(executable_path) && File.exist?(executable_path)
          end
        end
        nil
      end
      # rubocop:enable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity

      # Split command string
      #   split_command_string "deno run" # ["deno", "run"]
      # @param [String] command command string
      # @return [Array<String>] array split from the command string
      def split_command_string(command)
        regex = /([^\s"']+)|"([^"]+)"|'([^']+)'(?:\s+|\s*\Z)/
        command.scan(regex).flatten.compact
      end
    end
  end
end
