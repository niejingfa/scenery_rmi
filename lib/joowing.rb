#encoding: utf-8
module Joowing
  #
  # = 通用的joowing异常
  #
  # 各个FE/BE系统应该基于本异常建立自身的异常体系
  # 如，在 nebula-3 里面:
  #
  #     module Nebula
  #       class NebulaError < ::Joowing::Error; end
  #       class ClientSideError < NebulaError; end
  #       class ServerSideError < NebulaError; end
  #       class InternalError < ServerSideError; end
  #       class AuthenticationError < ClientSideError; end
  #       class SessionExpiredError < ClientSideError; end
  #     end
  # 在 pomelo backend 里面，也可能会建立一套自身的异常体系
  #     module PomeloBackend
  #       class Error < ::Joowing::Error; end
  #       class MobileSideError < Error; end
  #       class BackendError < Error; end
  #     end
  #
  # 在每个子系统的API中，会将异常，封装成为:
  #     {class: 'Nebula::AuthenticationError', ancestors: 'ClientSideError,NebulaError', code: ...}
  # Joowing RMI生成的动态接口类，在调用时，如果返回的http status为400/500系列错误，会先检查 http body是否为这种异常信息，如果是，
  #     则会将该异常转存在如下namespace中的异常:
  #     Joowing::Error::NebulaError::ClientSideError::AuthenticationError
  #     这些异常，类的继承关系和作为常量的ns空间关系保持一致
  #
  # 而调用者，可以基于这些异常的这层关系，进行如下捕捉
  #
  #     begin
  #       Joowing::Nebula::Session.login(user,pwd)
  #     rescue Joowing::Error::NebulaError::ClientSideError => e
  #       # do some thing for this code branch
  #       # even throw it to outside be handled by client side
  #     end
  #
  class Error < StandardError
    # 本类型中有的典型错误码
    #  这个错误码会向下传播，不会向上
    # class_attribute :codes
    # 异常关键属性
    #  code: 前端或者类似的表现层在翻译异常时，可以根据该code进行判断
    #  args: 在进行异常翻译时，辅助的翻译参数，基于Message Format格式要求，给定hash结构
    attr_accessor :code, :args
    # 异常扩展字段
    #   class_name是为了能够重现原始类
    #   status是为了能够重现原始错误的http status code
    attr_accessor :class_name, :status

    #
    # == 构建异常
    #
    # @param message 异常消息
    # @param code 异常业务码
    # @param args 在进行异常翻译时，辅助的翻译参数，基于Message Format格式要求，给定hash结构
    # 在args中可以对class_name， status(http status)进行定义
    def initialize(message, code = nil, args = {}, backtrace = [])
      super(message)
      self.code = code
      self.args = args
      self.set_backtrace(backtrace) unless backtrace.empty?
      self.class_name = self.args.delete(:class_name) || self.args.delete('class_name')
      self.status = self.args.delete(:status) || self.args.delete('status')
    end

    def to_json
      {code: code, status: status, args: args, backtrace: self.backtrace, message: message, class: self.class_name || self.class.name, ancestors: string_ancestors.join(',')}
    end

    #
    # ==返回Error的子类的上级类路径，到Joowing::Error为止(不包括)
    #
    def string_ancestors
      klasses = self.class.ancestors
      klasses.delete_if{|klass| !klass.is_a?(Class) || ::Joowing::Error.ancestors.include?(klass)}
      klasses.map! do |klass|
        name = klass.name
        name.gsub!(/[^:]+::/, '')
        name
      end
      klasses.reverse!
      klasses
    end

    class << self
      #
      # ==动态创建子错误类型，并基于namespace结构进行继承
      #
      #   这种自动创建的错误类型，是为了Joowing RMI的调用者，可以在不知道远端类实际体系的情况下的异常捕捉
      #
      #   实现这个机制，需要远端类在序列化输出时，将自身的上级类名(一直到JoowingError)放在其ancestors属性中
      #
      def const_missing(name)
        self.const_set(name.to_sym, Class.new(self))
      end

      #
      # ==注册异常码
      #
      # @params code 异常码，会自动转化为大写格式
      def define_error_code(code)
        code = code.to_s.upcase
        self.const_set(code.intern, code)
      end

    end
  end

  #
  # == 对远端后台系统调用时发生的错误
  #
  class RemoteError < Error
    define_error_code(:APP_BACKEND)
    define_error_code(:STB_SERVER)
    define_error_code(:POMELO_BACKEND)
    define_error_code(:POMELO)
    define_error_code(:BI_BACKEND)
    define_error_code(:DATA_BACKEND)
    define_error_code(:MANGO_PORTAL)
    define_error_code(:UIMC)
    define_error_code(:DWZ)
    define_error_code(:REPORT_BACKEND)
    define_error_code(:NOTIFICATION_CENTER)
    define_error_code(:DEVICE_BACKEND)
  end

  class << self
    # 自动根据DSL元信息构建相应的动态ActiveResource模型
    #   应用于传统的采用 Joowing:: 开头访问远程API的场景
    def const_missing(name)
      JoowingRmi::Manager.application.joowing_autoload(self, name)
    end

  end
end