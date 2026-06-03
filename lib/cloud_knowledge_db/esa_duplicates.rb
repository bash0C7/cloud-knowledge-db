# frozen_string_literal: true

module CloudKnowledgeDb
  # esa post の重複検出ロジック。
  #
  # 重複の単位は base name（`name` から esa 自動採番 ` (N)` suffix を除いたもの）。
  # date での絞り込みは post の content date（`name` 先頭の `YYYY-MM-DD-`）で行う。
  # esa の created_at（API の `created:` 検索）は後日再投稿で content date とズレるため使わない。
  module EsaDuplicates
    module_function

    SUFFIX_RE = / \(\d+\)$/

    def base_name(name)
      name.sub(SUFFIX_RE, '')
    end

    # posts: esa API の posts 配列（要素は 'name' / 'number' / 'full_name' を持つ Hash）
    # date:  'YYYY-MM-DD' を渡すとその content date の post だけを対象にする
    # 戻り値: [{ base_name:, posts: [...] }, ...]（count > 1 のグループのみ）
    def duplicate_groups(posts:, date: nil)
      list = posts || []
      list = list.select { |p| base_name(p['name']).start_with?("#{date}-") } if date

      list.group_by { |p| base_name(p['name']) }
          .select { |_base, group| group.length > 1 }
          .map { |base, group| { base_name: base, posts: group } }
    end
  end
end
