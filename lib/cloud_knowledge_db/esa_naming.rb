# frozen_string_literal: true

module CloudKnowledgeDb
  # esa API は name をタイトル、category を階層として分けて受け取る。
  # name にパスを入れると category と結合されて二重プレフィックスになるため、
  # ここで分離規則を明示化して仕様として固定する。
  module EsaNaming
    module_function

    def build_name(date:, short_name:)
      "#{date}-#{short_name}-cloud-changes"
    end

    def build_category(prefix:, date:)
      "#{prefix}/#{date.tr('-', '/')}"
    end
  end
end
