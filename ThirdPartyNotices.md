# 第三方许可说明

LightMD 的原创代码和文档采用仓库根目录的 MIT 许可证。下列第三方组件仍由各自的版权和许可证约束；项目许可证不替代其原有条款。

| 组件 | 用途 | 版本或来源 | 许可 |
| --- | --- | --- | --- |
| Swift Markdown | Markdown 语法解析 | [源码](https://github.com/swiftlang/swift-markdown)，具体提交见 Package.resolved | Apache-2.0，附 Runtime Library Exception；[LICENSE](docs/licenses/swift-markdown-LICENSE.txt)、[NOTICE](docs/licenses/swift-markdown-NOTICE.txt) |
| swift-cmark | 底层 Markdown 解析 | [源码](https://github.com/swiftlang/swift-cmark)，具体提交见 Package.resolved | BSD-2-Clause 及包含组件各自条款；[COPYING](docs/licenses/swift-cmark-COPYING.txt) |
| MathJaxSwift | 离线数学排版接口 | [3.5.0](https://github.com/colinc86/MathJaxSwift) | [MIT](docs/licenses/MathJaxSwift-LICENSE.txt) |
| MathJax 与其打包组件 | 数学排版运行资源 | 由固定版本 MathJaxSwift 提供 | 上游资源中的版权和许可证；相关声明保留在资源包内 |
| SwiftDraw | SVG 绘制 | [0.27.0](https://github.com/swhitty/SwiftDraw) | [MIT](docs/licenses/SwiftDraw-LICENSE.txt) |
| Mermaid Tiny 及其打包组件 | 离线图表排版 | [11.17.2](https://github.com/mermaid-js/mermaid) | [MIT](Assets/Mermaid/LICENSE)；发布脚本中的附带版权和许可注释原样保留 |

## 项目补丁

- `cmark-cjk-emphasis.patch`：在固定版本解析器上添加限定的中文标点强调兼容规则。
- `mathjax-app-resources.patch`：让运行资源从应用标准 Resources 目录加载。

上述修改保留上游版权与许可。构建脚本将相关声明随应用打包。字体由系统提供，本仓库不分发字体文件。
