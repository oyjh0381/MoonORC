# MoonORC 增量功能：2026-11-06

状态：本地未发布增量。使用本目录源码运行，已发布的 0.1.0 不包含本页新增 API。

## 稳定多列类型排序与精确类型键稳定去重
`Batch::sort_rows(keys, limits~)` 接受 SortKey 的 column/descending/nulls_first。
按声明列类型比较，Int64 不转 Double，字符串按 UTF-8 字节序，null 位置独立于方向。
NaN 在升序数值之后，降序在数值之前；NaN 之间及正负零在排序上相等，原行序打破全部平局。
不支持 Binary 排序；拒绝空、重复、未知键。返回新 Batch，不改源数据。

`Batch::unique_rows(keys, limits~)` 保留各精确键的第一行。
使用类型标签与长度框定编码，避免多列文本拼接碰撞；Binary 按字节、Real 按 IEEE 原始位型。
因此正负零、不同 NaN payload 在去重中不同，null 键彼此相同。这是位型身份去重，不是 SQL 数值相等判断。
输入/输出遵循行、列、解码字节预算；另对保留的去重键文本设置 max_decoded_bytes 上限，Binary 展开分配前检查。

用于幂等日志摄取、可重复列式导出、离线 ETL 的首条事件保留，以及精确大整数 ID 的归档。
不实现外部排序、分布式 shuffle 或任意 SQL ORDER BY。

排序时间 O(N log N*K*C+N*F)，空间 O(N*F+N)，C 为单键比较成本、F 为列数。
去重期望时间 O(输入校验+键字节+输出字节)，空间 O(保留键字节+输出列槽位)。
字符串排序比较按需编码；超大数据应先限制 batch 大小，不宣称流式外存排序。
测试覆盖大于 2^53 的整数、稳定平局、多列方向、null、NaN 位型、文本框定碰撞、Binary、预算和源数据隔离。

## 运行

```sh
moon run examples/expansion --target native --deny-warn
moon test --target all --deny-warn
```

Windows 使用 README 中对应的 Moon 包装脚本替代 `moon`。
CI 已添加该示例；无需网络服务、私钥或真实设备。
