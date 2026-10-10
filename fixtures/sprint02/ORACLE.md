# Independent sprint02 hand oracle

order.csv: first-seen case order c1,c2. source sequences ACB,AB; timestamp stable sequences CBA,AB. cases2/events5/activities3, counts A2 B2 C1. Source edges AC1 CB1 AB1; timestamp CB1 BA1 AB1. c1 original row ordinals must preserve provenance despite sorting; exact zero/one based ordinal interface pending. c1 equal09:00 events retain C before B. All offsets +05:00 normalize UTC minus five hours. lifecycle retained without collapsing.

quoted.csv: two distinct case names ` id ` and `id`; first sequence [`Әрекет;бір`,`two\nlines`], second [`say "yes"`]. cases2/events3/activities3, one edge; quoted physical newline is part of activity. Spaces and Unicode unchanged.

Existing manual.xes reused unchanged: ABC,ABC,AC,AA. RemoveB projection: AC,AC,AC,AA => cases4/events8/activities2, A5 C3, AC3 AA1; retainB gives B,B,empty,empty => cases4/events2/activities1, no edges, variantsB2 andempty2. Original case containsB AND length3 then removeB => AC,AC (cases2/events4/AC2); predicates must inspect original source before event projection. Conflict retain/removeB rejects.

Calendar fixed+05:00 Mon–Fri09–18: Fri2026-10-09 17:00 to Mon2026-10-12 10:00 =2h; full Monday9h; Fri18→Mon09=0; holidayMonday makes Fri17→Tue10=2h. Offset boundaries are computed from local civil time, not UTC weekday. Start=end zero; end<start invalid. Span min/max of unordered timestamp events is distinct from source first/last.

BPMN fixtures/tests await PM exact API; persistent/auth/live contracts await root. No implementation output was used to manufacture expected counts. These are prospective fixtures, not execution PASS.
