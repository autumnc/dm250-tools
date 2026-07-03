#!/bin/bash
weather=$(wget -qO- "wttr.in/jinjiang?format=晋江+%C+温度%t+(体感%f)+湿度%h&lang=zh") 
tmux display-message "$weather"
