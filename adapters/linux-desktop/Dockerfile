FROM mosaicrestore/p5-linux-runtime:20261004
ENV DISPLAY=:1 XDG_SESSION_TYPE=x11 NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility
RUN /opt/lada/.venv/bin/python -m pip install playwright==1.55.0 \
    && /opt/lada/.venv/bin/python -m playwright install --with-deps chromium
COPY adapters/windows_gui_agent.py adapters/linux_gui_agent.py /opt/p5/
COPY adapters/linux-desktop/start.sh adapters/linux-desktop/start-xfce.sh adapters/linux-desktop/agent.json /opt/p5/
COPY verify/p5_desktop_reconnect.py verify/p5_linux_fixture_server.py verify/p5_linux_fixture_task.py verify/run_p5_linux.py /opt/p5/
COPY verify/p5_local_cpu_server.py verify/p5_runtime_guards.py verify/p5_desktop_probe.py /opt/p5/
RUN ffmpeg -v error -i /opt/p5/fixtures/input.mp4 -t 10 -vf scale=160:90 -r 2 -c:v libx264 /opt/p5/fixtures/local-cpu.mp4
RUN chmod +x /opt/p5/start.sh /opt/p5/start-xfce.sh
EXPOSE 6080 8765
HEALTHCHECK --interval=30s --timeout=25s --start-period=60s --retries=2 CMD /opt/lada/.venv/bin/python /opt/p5/p5_desktop_probe.py --local || exit 1
ENTRYPOINT ["/opt/p5/start.sh"]
