# Workout Review

## Activity evidence

The activity list gives each activity an `id`, a title, a sport, a local start, a
duration, and a distance and, when recorded, Load, Intensity, average and weighted
average power, average and maximum heart rate, elevation gain, and FTP. Activity detail
adds, when recorded, the athlete's notes, indoor or not, RPE, feel, average cadence,
average and maximum speed, calories, work, variability index, efficiency factor,
decoupling, and the time in each power zone and each heart-rate zone. It also adds
`laps` when intervals.icu supplies them: each lap has its number, a label or kind,
and the same measurements as a listed activity.

These reads hold no planned targets, no plan compliance, and no wellness. A measurement
that is absent is unavailable. Do not infer it from another measurement.

## Multisport evidence

A recorded workout can contain more than three ordered sport and transition activities.
intervals.icu does not mark which activities belong to one workout, so legs are inferred
from starts within 30 minutes of each other. Summarize every leg in start-time order
and say the grouping is inferred. If detail is
requested for only one leg, say which legs were not detailed and do not use that leg
alone to judge the whole workout or change the next session.

## Show numbers — the cycling rows

Summary/detail table rows:

| Metric                           | Value                                              |
| -------------------------------- | -------------------------------------------------- |
| Date / start                     | local date and local time; date alone when no time |
| Sport                            | sport                                              |
| Duration                         | hh:mm:ss                                           |
| Distance                         | km                                                 |
| Load                             | recorded value                                     |
| Intensity                        | %                                                  |
| Average / weighted average power | W / W                                              |
| Average / max HR                 | bpm / bpm                                          |
| Elevation gain                   | m                                                  |
| FTP                              | W                                                  |

After an activity detail read, append only the rows it supplied:

| Metric                                | Value             |
| ------------------------------------- | ----------------- |
| Indoor                                | yes / no          |
| RPE / feel                            | recorded values   |
| Average cadence                       | rpm               |
| Average / max speed                   | km/h              |
| Calories                              | kcal              |
| Work                                  | kJ                |
| Variability index / efficiency factor | recorded values   |
| Decoupling                            | %                 |
| Time in power / heart-rate zones      | hh:mm:ss per zone |

For Tier C, append only stream rows backed by requested channels:

| Metric             | Value |
| ------------------ | ----- |
| Mean / max power   | W     |
| Mean / max HR      | bpm   |
| Mean cadence       | rpm   |
| Min / max altitude | m     |

When `laps` are supplied, the lap table columns are:

| Lap | Label / kind | Duration | Distance |
| --- | ------------ | -------- | -------- |

Add an average power column and an average HR column when any lap has that measurement.

Render a missing value as unavailable rather than zero.
