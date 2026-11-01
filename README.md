# MoonORC

MoonBit 原生、具有明确兼容边界的 ORC 列式记录交换与选择扫描库。核心不绑定 C++/Java；native、JavaScript、Wasm、Wasm-GC 共用一套编码与扫描逻辑。Apache ORC C++ 仅通过 pyorc 用作独立开发测试对照，不是运行依赖。

当前是**本地预发布**：`local/moonorc`、`private = true`，未创建远程仓库或发布包。所有者确定真实账号后才会配置公开模块名与安装地址；现在不要执行 `moon add local/moonorc`。

## 解决什么问题

ORC 将可空的表记录拆成带类型的列流和独立 stripe，支持只解码需要的字段，并可利用可信统计跳过不可能匹配的 stripe。本项目补充这种真实格式的原生读写/扫描能力，而非重造 SQL、DataFrame 或纯压缩库。

- 服务日志/应用事件：保存稳定类型和空值，分析时只读请求标识、状态码等需要的字段。
- 数据管道/业务导出：按名字对齐不同版本的记录字段，保留缺失字段为空，交给已有 ORC 工具消费。
- 离线分析/Web/WASM：在不装 C++ 运行时的环境中筛选日期、分组标签和数值列，再交给上层统计或可视化组件。

它与 HDF5 多维数组/区域访问、SDMX 结构化统计交换、外部排序和 Arrow 内存布局都不是同一核心能力；也不声称替代这些组件。

## 环境与复现

安装 [官方 MoonBit 工具链](https://docs.moonbitlang.com/en/latest/download-and-install.html)，推荐已验证的 `moonc 0.10.16` 或兼容更新版本。在本项目目录执行：

```sh
moon version --all
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
moon run examples/log_export
moon run examples/etl
moon run examples/offline_analysis
moon run examples/scale --target native --release
```

依赖版本固定在 `moon.mod`；工具链会按需解析依赖。Windows 的 Moon 20261016 OCaml 子工具可能不能处理驱动传入的 `\\?\` 路径，可使用随项目的参数适配器（首次需 MSVC Build Tools）：

```powershell
.\tools\windows\moon.ps1 check --target all --deny-warn
.\tools\windows\moon.ps1 test --target all --deny-warn
.\tools\windows\moon.ps1 run examples/log_export
```

它只生成 `_build` 文件并设置进程级参数覆盖；不替换编译器、不修改全局环境。其他平台直接使用标准 `moon` 命令。

## 最小使用样例

应用包的 `moon.pkg` 导入 `"local/moonorc" @orc`；完整可运行版本见 `examples/log_export`。

```moonbit
fn main raise {
  let schema = @orc.Schema::new([
    { name: "id", kind: Long },
    { name: "label", kind: String },
  ])
  let batch = @orc.Batch::new(schema, [
    [Integer(1L), Null, Integer(3L)],
    [Text("a"), Text("b"), Text("c")],
  ])
  let file = @orc.OrcFile::open(@orc.write(batch))
  let scan = file.scan(
    columns=Some(["label"]),
    predicate=Compare("id", Greater, Integer(2L)),
  )
  assert_eq(scan.next().unwrap().column("label"), [Text("c")])
}
```

整数 `Cell::Integer` 保留完整 Int64，不经过 Double。日期 `Days` 是 Unix epoch 起的天数，不是时间戳；Float 字段按 IEEE32 舍入，Double 按 IEEE64，负零和 Double NaN payload 在核心字节交换中保留。`Null` 不等于空字符串、空二进制或零。

## 接口与功能

- `Schema`、`Batch`：验证平坦可空类型列，拒绝空/重复字段名、类型不符和不同列行数；可变数组通过防御性复制隔离。
- `Batch::project/align/rename/take/slice`、`concat`：明确字段映射和空值扩展；不执行隐式类型强制转换。
- `write`：从完整批次产生确定性 ORC 文件；`Writer::push/finish` 支持增量输入，分批编码，失败 push 不破坏此前内容。writer 保留编码后的输出，**不是磁盘流式写入**。
- `OrcFile::read_stripe`：列投影读取；数据流位置以 stripe footer 为准，不假设列流按固定顺序排列。
- `OrcFile::scan`：投影字段和谓词所需字段解码，三值空语义精确过滤，按 `batch_rows` 分批返回。`row_start/row_count` 是**过滤前源记录范围**，不是过滤后的 OFFSET/LIMIT。
- `Compare/IsNull/And/Or/Not`：类型一致的谓词。空值比较为 unknown，unknown 在 WHERE 式过滤中不返回。NaN 的有序比较/相等比较均不成立，NOT 遵循该结果；不存在二进制比较。
- `stripe_statistics`、`row_groups`、`plan_stripe`：查看统计、行组位置和精确编码字节范围。行组 API 不承诺按行组 seek/解码；range 计划也不是网络下载器。

## 统计裁剪的信任边界

默认 `trust_statistics=false`，仍执行精确行过滤，但不靠 min/max 跳过 stripe。明确设置为 true 时，调用方须信任文件生产者：ORC 的统计本身没有认证，恶意文件可以伪造它。测试专门验证了默认模式不会因为伪造空统计而漏行。

裁剪只证明“不可能匹配”，不能把保留 stripe 当作全部行匹配。缺失/截断式字符串统计和浮点边界保守处理；NOT 不作统计反转优化。UTF-8 字符串按字节字典序比较，不使用 UTF-16 代理项顺序。正常扫描过程中发现解码错误后，该 Scanner 永久失败，重试不会悄悄跳过坏 stripe。

## 格式兼容范围

| 方面 | 已实现 | 明确不支持/不承诺 |
| --- | --- | --- |
| 文件 | ORC 0.11/0.12 入口、protobuf tail/stripe、用户元数据 | 加密、活动文件恢复、事务/ACID、任意未来版本 |
| Schema | flat struct：boolean、byte/short/int/long、float/double、string、binary、date | nested/list/map/union、decimal、timestamp、char/varchar |
| 编码读取 | byte/boolean RLE、整数 RLEv1、RLEv2 四模式、直接与字典字符串 | 自定义列编码、未验证类型变体 |
| 压缩 | NONE、ZLIB（ORC raw DEFLATE 分块） | SNAPPY/LZO/LZ4/ZSTD |
| 写出 | ORC 0.12、DIRECT/RLEv1、重复字符串字典、nullable、多 stripe、NONE/ZLIB、用户元数据和 stripe 统计 | row-index/bloom 写出、加密、其他 codec |
| 日期 | 写出 proleptic Gregorian；读取现代日期及显式 proleptic 文件 | hybrid 日历中改革前日期自动换算 |
| 扫描 | 整 stripe 解码所需列、源行范围、可信 stripe 裁剪、精确行过滤 | SQL、row-group seek、Bloom 裁剪、远程 range IO |

RLEv2 的公开规范样例和独立 Apache ORC fixtures 已覆盖；这不是对所有 ORC 生产者/历史变体的穷尽认证。无损“重写”只指受支持 schema 下的记录值和用户元数据；不保留原 stripe 物理布局、编码选择、索引、原始统计、writer 信息或压缩字节。开文件时校验入口/目录，列内容在读取时校验；不会为投影读取检查无关列。

## 原生文件工具

```sh
moon run cmd/main --target native -- demo NEW.orc
moon run cmd/main --target native -- read INPUT.orc
moon run cmd/main --target native -- rewrite INPUT.orc NEW.orc
```

写入使用 `CreateNew`，拒绝覆盖已有文件。`read` 的 JSON 中整数使用十进制字符串，二进制使用字节数组，日期使用天数，NaN/Infinity/负零使用特殊字符串；适合小数据验证，不是完整可互换的 JSON Schema 标准。`rewrite` 目前在内存中收集结果，适合受限输入；大规模应用应使用批次 API。

## 独立验证与 CI

```sh
python -m venv _local/venv
# 激活该环境，Windows 也可直接使用 _local\venv\Scripts\python.exe
python -m pip install -r scripts/requirements-interop.txt
moon build --target native --deny-warn
python scripts/interop.py verify _build/native/debug/build/cmd/main/main.exe
python scripts/verify_repository.py
```

pyorc 对照脚本比较 Apache ORC→MoonORC 读取、MoonORC→Apache ORC 读取、重新编码、空值/类型、64位边界和拒绝覆盖等行为。`fixtures/*.orc` 仅含项目自造数据；可用 `scripts/interop.py generate fixtures` 生成，再运行 `scripts/embed_fixtures.py` 与 `moon fmt`。嵌入字节是生成**数据**，不计入有效代码行数。

GitHub Actions 已配置 check/build/test 四后端、fmt/API 一致性、三个场景、规模负载和独立互操作。远程运行成功记录只有在公开推送后才能确认；本地通过不是正式赛事验收结论。

## 资源与性能

默认文件/输出及单次逻辑解码预算各 256 MiB，文件最多 100万行、256列、1万stripe，protobuf 消息字段和展开谓词节点最多10万，谓词深度64。地址/长度必须适合 MoonBit Int。预算不是进程精确峰值内存：输入文件、解码字节、Cell 数组、复制与输出可能并存，不能当作零复制或超大文件服务。

读取当前接受完整内存 Bytes；投影可减少解压/解码，但不减少最初整个文件的传输。批次返回量可控，命中 stripe 的所需列仍整体解码。schema 名字索引平均 O(1)，stripe 统计目录只解析一次，避免逐 stripe 重扫 metadata；编码与读取近似 O(所处理流字节+记录单元)，谓词为 O(行数×谓词节点)。返回批次/字段对齐复制需要 O(输出单元) 空间。规模例是可复现正确性负载，不宣称性能优于 Apache ORC。

## 来源、许可证与维护

依据 [Apache ORC 官方规范](https://orc.apache.org/specification/ORCv1/) 独立实现；Apache-2.0，详见 [THIRD_PARTY.md](THIRD_PARTY.md)、LICENSE 和 NOTICE。使用 AI 辅助开发，行为由标准样例、属性测试、跨后端测试和独立工具验证；这不替代使用者对实际数据和风险的检验。

领域术语在 `CONTEXT.md`，边界决策在 `docs/adr/`，公共 API 在 `pkg.generated.mbti`。后续优先修复真实兼容缺陷；新增 codec 或嵌套类型必须带独立 fixture 后再扩展声明。申报书、审查、AI 辅助和汇总材料留在 `_local/` 或仓库外，不进入 Git 或发布包。


## 十一月新增功能

**消费方字段契约检查**（`Schema::check_contract`）；**保留源文件行号的选择扫描**（`Scanner::next_positioned`）。详见[功能、用途和边界](docs/NOVEMBER_FEATURES.md)，运行 `moon run examples/november --target native --deny-warn`。当前仍为本地未发布源码，不提供虚构安装地址。
