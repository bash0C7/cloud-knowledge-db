# frozen_string_literal: true
class FakeAnthropicClient
  attr_reader :calls

  def initialize(responses: [])
    @responses = responses
    @calls     = []
  end

  def messages
    @messages ||= MessagesProxy.new(self)
  end

  class MessagesProxy
    def initialize(client); @client = client; end
    def create(**kwargs)
      @client.calls << kwargs
      response = @client.instance_variable_get(:@responses).shift || default_response
      Object.new.tap do |o|
        text = response
        o.define_singleton_method(:content) { [Object.new.tap { |c| c.define_singleton_method(:text) { text } }] }
      end
    end
    private
    def default_response; '訳文サンプル'; end
  end

  def models
    raise NotImplementedError
  end
end
