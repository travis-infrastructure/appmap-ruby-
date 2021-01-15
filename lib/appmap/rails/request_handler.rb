# frozen_string_literal: true

require 'appmap/event'
require 'appmap/hook'

module AppMap
  module Rails
    module RequestHandler
      class HTTPServerRequest < AppMap::Event::MethodEvent
        attr_accessor :normalized_path_info, :request_method, :path_info, :params

        def initialize(request)
          super AppMap::Event.next_id_counter, :call, Thread.current.object_id

          @request_method = request.request_method
          @normalized_path_info = normalized_path request
          @path_info = request.path_info.split('?')[0]
          # ActionDispatch::Http::ParameterFilter is deprecated
          parameter_filter_cls = \
            if defined?(ActiveSupport::ParameterFilter)
              ActiveSupport::ParameterFilter
            else
              ActionDispatch::Http::ParameterFilter
            end
          @params = parameter_filter_cls.new(::Rails.application.config.filter_parameters).filter(request.params)
        end

        def to_h
          super.tap do |h|
            h[:http_server_request] = {
              request_method: request_method,
              path_info: path_info,
              normalized_path_info: normalized_path_info
            }.compact

            h[:message] = params.keys.map do |key|
              val = params[key]
              {
                name: key,
                class: val.class.name,
                value: self.class.display_string(val),
                object_id: val.__id__
              }
            end
          end
        end

        private

        def normalized_path(request)
          route = ::Rails.application.routes.router.enum_for(:recognize, request).first
          route.first.path.spec.to_s if route
        end
      end

      class HTTPServerResponse < AppMap::Event::MethodReturnIgnoreValue
        attr_accessor :status, :mime_type

        def initialize(response, parent_id, elapsed)
          super AppMap::Event.next_id_counter, :return, Thread.current.object_id

          self.status = response.status
          self.mime_type = response.headers['Content-Type']
          self.parent_id = parent_id
          self.elapsed = elapsed
        end

        def to_h
          super.tap do |h|
            h[:http_server_response] = {
              status: status,
              mime_type: mime_type
            }.compact
          end
        end
      end

      class HookMethod < AppMap::Hook::Method
        def initialize
          # ActionController::Instrumentation has issued start_processing.action_controller and
          # process_action.action_controller since Rails 3. Therefore it's a stable place to hook
          # the request. Rails controller notifications can't be used directly because they don't
          # provide response headers, and we want the Content-Type.
          super(nil, ActionController::Instrumentation, ActionController::Instrumentation.instance_method(:process_action))
        end

        protected

        def before_hook(receiver, defined_class, _) # args
          call_event = HTTPServerRequest.new(receiver.request)
          # http_server_request events are i/o and do not require a package name.
          AppMap.tracing.record_event call_event, defined_class: defined_class, method: hook_method
          [ call_event, TIME_NOW.call ]
        end

        def after_hook(receiver, call_event, start_time, _, _) # return_value, exception
          elapsed = TIME_NOW.call - start_time
          return_event = HTTPServerResponse.new receiver.response, call_event.id, elapsed
          AppMap.tracing.record_event return_event
        end
      end
    end
  end
end
