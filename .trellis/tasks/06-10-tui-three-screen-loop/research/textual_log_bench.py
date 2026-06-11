"""Headless benchmark: per-line call_from_thread vs batched write_lines on Log."""
import asyncio, time, threading
from textual.app import App, ComposeResult
from textual.widgets import Log

N = 5000

class LogApp(App[None]):
    def compose(self) -> ComposeResult:
        yield Log(max_lines=1000)

async def main() -> None:
    app = LogApp()
    async with app.run_test() as pilot:
        log = app.query_one(Log)
        # worst case: one call_from_thread per line
        done = threading.Event()
        def per_line():
            for i in range(N):
                app.call_from_thread(log.write_line, f"line {i} of streaming process output ............")
            done.set()
        t0 = time.perf_counter()
        threading.Thread(target=per_line, daemon=True).start()
        while not done.is_set():
            await pilot.pause()
        dt1 = time.perf_counter() - t0
        await pilot.pause()
        c1 = log.line_count
        # batched: 50-line batches per marshal
        done2 = threading.Event()
        def batched():
            batch = [f"batched line {i} of streaming process output ......." for i in range(N)]
            for i in range(0, N, 50):
                app.call_from_thread(log.write_lines, batch[i:i+50])
            done2.set()
        t0 = time.perf_counter()
        threading.Thread(target=batched, daemon=True).start()
        while not done2.is_set():
            await pilot.pause()
        dt2 = time.perf_counter() - t0
        await pilot.pause()
        print(f"per-line:  {N} lines in {dt1:.2f}s = {N/dt1:.0f} lines/s")
        print(f"batch(50): {N} lines in {dt2:.2f}s = {N/dt2:.0f} lines/s")
        print(f"line_count after each run (max_lines=1000): {c1} / {log.line_count}")

asyncio.run(main())
