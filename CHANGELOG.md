# Changelog

## 0.1.0 — 2026-11-01

- 消费方字段契约检查：Schema::check_contract
- 保留源文件行号的选择扫描：Scanner::next_positioned
- 增加边界回归、可运行集成示例和CI步骤。

### Initial implementation

- Independent native ORC flat record encoding, nullable columns and multi-stripe files.
- NONE/ZLIB framing, RLEv1/v2 reads, direct and dictionary strings.
- Projection, exact three-valued filtering, source-row windows, opt-in trusted statistics pruning.
- Atomic incremental input writer, immutable batch operations, stream range and row-group metadata inspection.
- Independent Apache ORC oracle, cross-backend fixtures and tests, application scenarios and scale workload.
- Public namespace: oyjh0381/moonorc; reproducible compiler/core, Linux/Windows CI and history/package hygiene checks.
