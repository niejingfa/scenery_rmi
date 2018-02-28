#encoding: utf-8
module SceneryRmi::Definition
  class AttributeDefinition < Struct.new(:name, :type, :array, :default_value)
    def initialize(*args)
      options = args.extract_options!
      super(*args)
      options.each_pair{|k,v| self.send("#{k}=", v)}
      self.array = false if self.array.nil?
      self.default_value = nil
    end

    def assign_default_value_to(obj)
      obj.send("#{name}=", self.default_value) if self.default_value
    end

    def to_s(pk = false)
      pks = pk ? '(*)' : ''
      dft = self.default_value.blank? ? '' : ' = ' + self.default_value
      format '%s%s : %s%s', self.name, pks, self.type_string, dft
    end

    def type_string
      value = self.type.to_s
      value << '[]' if  self.array and value !~ /\[\]$/
      value
    end
  end
end