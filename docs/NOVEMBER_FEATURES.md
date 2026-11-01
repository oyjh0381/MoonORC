# MoonORC 十一月功能扩展

日志、业务导出和离线分析需要读取少量列及筛选记录，并把异常定位回原始文件。项目补充真实 ORC 文件读写能力，新增无隐式转换的消费者字段契约和源行证据，让上层ETL或分析器在读取前核对字段，在过滤后保留定位信息。

## 1. 消费方字段契约检查

`Schema::check_contract`：按字段名称和精确Kind检查消费者所需字段，报告missing、incompatible和extra；字段顺序不影响结果，额外字段可保留，不自动做数值扩大或填补。

复杂度与代价：预期O(来源列+所需列)时间与空间；检查类型契约不证明数据非空、业务约束或全部列内容正确。

## 2. 保留源文件行号的选择扫描

`Scanner::next_positioned`：返回批次与0起始源文件行号，穿过列投影、谓词过滤、多个stripe和分页后仍能定位原记录；可与next交替调用并共享同一游标。

复杂度与代价：在原过滤循环增加行号数组，额外O(命中stripe的筛选行数)空间；不增加第二次谓词求值。不是row-group seek或远程range IO。

## 运行

```sh
moon run examples/november --target native --deny-warn
moon check --target all --deny-warn
moon build --target all --deny-warn
moon test --target all --deny-warn
```

Windows当前工具链路径问题沿用README的项目适配脚本；正式命名空间为 `oyjh0381/moonorc`，安装方式见README。

## 范围

不实现SQL引擎、nested/decimal/timestamp、所有压缩codec、row-group seek、远程下载或任意大文件流式IO；统计默认不可信，当前完整输入和命中stripe的所需列仍驻内存。

Apache ORC双向类型/空值/多stripe验证；新增契约、跨stripe行号、混合next和next_positioned测试。 具体当前执行结果由本地检查记录提供，不以CI配置代替远端成功记录。
