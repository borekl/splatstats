# splatstats
DCSS Tournament TeamSplat Statistics

Simple clan scoreboard meant to supplement the 0.25 official scoreboard, which is fairly incomplete at this moment. This is very quick and dirty effort as it was started mere two days before the tournament was to begin. The tournament was then pushed back one week, so there was little more time to finish it and add little polish. It is configured through the `config.json` file, which should be self-explanatory.

The script keeps local data in `state.json` file. This is created on the first run, which will probably take quite long (depends on the size of server logs, but it can be minutes). Subsequent runs retrieve only increments of the logs and will run much faster, so it's safe to invoke this every minute.
