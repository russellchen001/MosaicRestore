#!/bin/bash
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec dbus-run-session -- startxfce4
