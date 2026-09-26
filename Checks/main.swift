import Markdown
import Foundation

struct Case {
    let source: String
    let required: [String]
    let forbidden: [String]
}

let cases: [Case] = [
    .init(source: "前**“重点”**后", required: ["Strong", "“重点”"], forbidden: []),
    .init(source: "**结束。**随后", required: ["Strong"], forbidden: []),
    .init(source: "**结束。**Next", required: ["Strong"], forbidden: []),
    .init(source: "**停顿，**继续", required: ["Strong"], forbidden: []),
    .init(source: "**注意！**继续", required: ["Strong"], forbidden: []),
    .init(source: "前*（解释）*后", required: ["Emphasis"], forbidden: []),
    .init(source: "前***「重点」***后", required: ["Strong", "Emphasis"], forbidden: []),
    .init(source: "__结束。__随后", required: ["Strong"], forbidden: []),
    .init(source: "~~删除。~~随后", required: ["Strikethrough"], forbidden: []),
    .init(source: "# 标题 **“重点”**后", required: ["Heading", "Strong"], forbidden: []),
    .init(source: "> 前*（解释）*后", required: ["BlockQuote", "Emphasis"], forbidden: []),
    .init(source: "| 项目 | **“重点”**后 |\n| --- | --- |\n| A | 内容 |", required: ["Table", "Strong"], forbidden: []),
    .init(source: "[甲**“乙”**后][]\n\n[甲**“乙”**后]: other.md", required: ["Link destination: \"other.md\"", "Strong"], forbidden: []),
    .init(source: "`**代码。**`后文", required: ["InlineCode `**代码。**`"], forbidden: ["Strong"]),
    .init(source: "```\n**代码。**后文\n```", required: ["CodeBlock"], forbidden: ["Strong"]),
    .init(source: "\\*\\*字面。**后", required: ["Text"], forbidden: ["Strong"]),
    .init(source: "** 前空格**", required: ["Text"], forbidden: ["Strong"]),
    .init(source: "前**正常**后", required: ["Strong"], forbidden: [])
]

for test in cases {
    let tree = Document(parsing: test.source).debugDescription()
    let missing = test.required.filter { !tree.contains($0) }
    let unexpected = test.forbidden.filter { tree.contains($0) }
    if !missing.isEmpty || !unexpected.isEmpty {
        fputs("CJK parser check failed for: \(test.source)\nMissing: \(missing) Unexpected: \(unexpected)\n\(tree)\n", stderr)
        exit(1)
    }
}
print("CJK parser checks passed (\(cases.count) cases)")
