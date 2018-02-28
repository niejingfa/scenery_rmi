#encoding: utf-8
require 'erb'
require 'yaml'
require 'ostruct'

module JoowingRmi
  module ErbYaml
    # 会运行其中erb的数据
    # erb中, 可以直接引用其 variables 下面的key为变量
    # @param [String, File] data erb格式的yaml, 或者是yaml格式的文件
    def self.load(data)
      data = data.read if data.is_a?(File)
      begin
        # 第一步, 尝试读取原始文件, 获取所有的变量
        raw = YAML.load(data)
      rescue # failed to 原先的方式
        return YAML.load(ERB.new(data).result)
      end
      variables = raw['variables']
      if variables and variables.is_a?(Hash)
        struct = OpenStruct.new variables
        struct.instance_eval do
          def get_binding
            binding
          end
        end
        # 支持以 ${xxx} 方式做字符串引用/替换
        new_data = data.gsub /\$\{([^}]+)\}/, '<%=\1%>'
        # 支持以更简单的 $xxx 方式做字符串引用/替换
        new_data.gsub! /\$(\w+)/, '<%=\1%>'
        begin
          YAML.load(ERB.new(new_data).result(struct.get_binding))
        rescue # failed to 原先的样式
          YAML.load(ERB.new(data).result)
        end
      else
        YAML.load(ERB.new(data).result)
      end
    end
  end
end