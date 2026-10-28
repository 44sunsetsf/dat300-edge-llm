# 最终报告（LaTeX）

- `main.tex`：报告正文（英文）。第 7、8、9 节是 2026-10-14 交换机 + 4 台 Pi 的实验，数据来自 `../docs/实验报告_1014.md` 和 `../logs/`。
- `figures/`：报告里的所有图（PDF 和 PNG 各一份），由 `make_figures.py` 生成。
- `make_figures.py`：画图脚本。【在笔记本上】运行 `python3 report/make_figures.py`（需要 matplotlib）。每块数据都注明了来自哪个测试编号的日志；每 token 时间拆分图直接读取 `logs/trace/` 里的计时日志。
- `slides.tex` / `slides.pdf`：最终答辩幻灯片（Beamer），作为报告附录 A 嵌入。
- `DAT300_Group7_Final_Report.pdf`：2026-10-28 提交到 Canvas（SW9 小组提交）的最终版（报告 + 幻灯片附录）。本地 tectonic 没有 gelasio 字体，所以用默认字体编译。

编译：先 `tectonic slides.tex` 生成 `slides.pdf`，再编译 `main.tex`（Overleaf 上要把 `slides.pdf`、`figures/` 一起上传）。
