# R5 Sprint19 — проект следующей конечной проверки

Статус: предложение Science/Service после чтения исходников. Java/Rust API не запускались, новые наблюдатели и fixtures не реализованы. Окно Sprint19: 2026-10-22 01:09:14–09:09:14 UTC, остановка новых native/build запусков в 07:39:14 UTC. R4 имеет первый приоритет; этот документ не утверждает выполнение или закрытие R5.

## Что уже есть и чего не хватает

Исходный `SPRINT_08_SCOPE.md` требует конечного согласованного списка фильтров с параметрами, границами, композицией и сохранением источника (R5-01), а для календаря — IANA/DST, версии базы, локальные выходные/праздники, gap/fold и отдельное сравнение legacy-семантики (R5-02). R5-03 conversions и R5-04 Split Miner остаются отдельными задачами.

Sprint18 дал шесть совпавших общих примеров настоящего CASE_EVENT_ATTRIBUTE и два диагностических различия; публичные доказательства находятся в `evidence/sprint18/core-filter`. Он не проверял min/max длины, проекцию событий и настоящую CalendarModel. Текущий Rust уже использует `chrono-tz = 0.10.4`, IANA 2025b и явный отказ для неоднозначной/несуществующей рабочей границы. Это описано в `IANA_CALENDAR.md` и покрыто собственными тестами; legacy calendar reference этим не заменяется.

## Настоящие API и доступность

Неизменённый upstream: commit `bbf24dfd43e72d6992392465f875a4367cbe792b`. Канонический S16 source/runtime читается без записи. Все нужные JAR уже входят в принятую цепочку 285 runtime-файлов; загрузка или новая сборка upstream не требуется.

Фильтры: целый `APMLogFilter.filterIndex(List<LogFilterRule>)`, настоящие XLogToImmutableLog/APMLog/PLog и RuleValue/LogFilterRuleImpl. Не вызывать отдельно извлечённые predicates. Один упорядоченный список правил соответствует порядку операций Rust `filters::apply`; повторные вызовы Java сбрасывают pointer traces и не являются AND-композицией.

Календарь: настоящий `CalendarModelBuilder.withWorkDay(DayOfWeek, LocalTime, LocalTime, boolean)`, `withHoliday(HolidayType.PUBLIC, name, description, LocalDate)`, `withZoneId(String)`, затем `build()` и `CalendarModel.getDuration(Instant, Instant)`. Создание использует `Calendars.INSTANCE.emptyCalendar()`, поэтому отражение защищённого конструктора, Spring/БД и подмена класса не нужны. `CalendarModel.getDuration(...).toMillis()` — основное сравнение с Rust `calendar::business_millis`. Отдельно наблюдать `getDurationMillis(...)`: это другой upstream метод со своей арифметикой округления, не скрытая замена основной операции.

Канонический `Apromore-Calendar-1.0-plain.jar` SHA256: `f29983b59677978b95131b02daa43680921f81fced061eb85865596c669d2b9a`.

| Класс | SHA256 исходника | SHA256 реального class-файла |
|---|---|---|
| CalendarModel | a0da7646745c1fa196bd49a6e3ce9900bbd567a04999192ef47839f1d0391149 | 875c96a343e48cdc42c613b5f65ba7b35056498e112ebffd865084c4ad8c1e39 |
| WorkDayModel | ff2570d272f01646e91092d74de917b0a26b9da85f60f6427a8db5f612dd3f4b | e9983bdef6b0fe12f0d7db7bb03c326fdb1259a69cdf34bb8e0d279bb3217207 |
| CalendarModelBuilder | 15c8be12c69939abc1810577c9f5a8777de5abe9d6909d89a63567e76616cbd5 | 8e2fefee2d943e7e8864d80d9cdfdaf8ce42ebb18e3002639d449a31c81096c5 |
| Calendars | 1ac4758bde49fecb0d3a0df850a21d01bfa9a2a042d2e80b486170f69ca9899a | ec2958c284cb6d88b4a69b3ff24668c7311ccd19cfcd4ed396486863252ac5b2 |
| CaseLengthFilter | 361619029f7887563157ca06a1843b91d574c2e412e20feb2c17ff5ce5ffa606 | 1409e5c3cf4e730cf33eae022fc159a29c557eb98106849523ddd1e0f86c64be |

Исходные Git blob identities сверены чтением байтов с pinned tree, классы прочитаны из канонических JAR без выполнения. Для APMLogFilter остаются прежние class SHA `b07c241d7d5a430f9fd1f6cea5eb696a71eefdee7dc268ee0c81d18c464769b3` и JAR SHA `4fc0c2cdd170c1f5cbf4fe542250c7b84deb2dfc583dc10631b6562b3894ef81`.

## Предлагаемые восемь следующих фильтровых примеров

Общая область прежняя: уникальные непустые имена кейсов, непустые трассы, явные complete-события, millisecond UTC timestamps. Здесь один event равен одному ActivityInstance. Start/complete pairing не входит в равенство длины.

Параметры длины: `CASE_LENGTH`, `RETAIN`, `Section.CASE`, RuleValue `GREATER_EQUAL` и `LESS_EQUAL` с числовыми long-границами. Для отсутствующего min задаётся 0, для отсутствующего max — Long.MAX_VALUE: upstream при отсутствии верхнего RuleValue сам оставляет upper=0, поэтому опускать правило и выдавать это за Rust None нельзя.

Проекция: `EVENT_EVENT_ATTRIBUTE`, `Section.EVENT`, key `concept:name`, RuleValue Set строк, `Choice.RETAIN` либо `REMOVE`. Адаптер выводит реальные PTrace immutable indexes и valid-event BitSet; восстанавливает исходные события только по фактически возвращённым индексам. Нельзя использовать APM-to-XES export или собственный membership predicate.

| ID | Вход и правило | Гипотеза Java / Rust до выполнения |
|---|---|---|
| length-closed | Длины 1,2,3,4; min=2,max=3 | Кейсы 1,2; границы включены |
| length-min-only | Те же; min=2,max=None | Кейсы 1,2,3 |
| length-max-only | Те же; min=None,max=2 | Кейсы 0,1 |
| length-invalid | Те же; min=3,max=2 | Java пустой PLog; Rust filter_range; диагностическое различие |
| retain-partial | AB,BAA; retain A | Оба кейса, исходные event positions [0] и [1,2] |
| remove-partial | AB,BAA; remove A | Оба кейса, positions [1] и [0] |
| remove-empty-case | A,BA; remove A | Java удаляет первый кейс; Rust сохраняет первый пустой кейс — диагностика |
| length-then-retain | AB,AAB,B; min=2, затем retain A | Кейсы 0,1 с событиями A и AA; исходные ordinal/time/lifecycle не меняются |

Не менять продукт ради legacy-похожести без отдельного решения. Два диагностических случая сохраняют различия. Остальные сравнивают полные identities/order/fields, warnings и источник до/после. Пустой PLog не преобразовывать обратно в ImmutableLog только для отчёта. Пустые retain/remove sets, конфликт retain/remove, paired lifecycle и фильтры времени/стоимости не получают credit от этой восьмёрки.

## Календарная семантика, которую нельзя смешивать

Реальная CalendarModel переводит UTC endpoints в выбранную ZoneId, а WorkDayModel затем считает длительность между локальными LocalDateTime/LocalTime. По прочитанному исходнику она считает локальные часы; Rust пересекает рабочие границы в UTC и считает реально прошедшее время. Поэтому весенний и осенний DST должны быть заранее объявлены сравнением разных семантик, а не подгонкой результата.

JDK11 `lib/tzdb.dat` прочитан как бинарные метаданные: TZDB format1, версия `2026b`, SHA256 `5906b44e25a8a730131d7ba1beb5d15af27043f6536f1a169ca8a5d8b8bed8f8`. Rust pinned база — `2025b`. Это пока не runtime ZoneRulesProvider proof: при разрешённом запуске вывести настоящие доступные версии по каждой зоне и не обещать равенство всех исторических правил. Корпус ниже использует заранее указанные UTC boundaries; часовые пояса ОС и сеть не участвуют.

Builder `withWork9to5Day` не использовать как скрытое исправление или shortcut: в pinned исходнике его конец задан как 05:00. Настраивать явные 09:00/18:00. Для 24h `LocalTime.MAX` отличается от Rust end_minute=1440 на наносекунду; этот случай требует отдельной гипотезы и здесь не входит в equality overlap. Несколько интервалов на один день и их пересечение также не входят в однооконный Rust contract.

## Предлагаемые 13 календарных примеров

Все значения ниже — гипотезы из независимых UTC границ и чтения исходника, а не уже полученные результаты. Основной Java метод — `getDuration(Instant,Instant).toMillis()`. До первого engine run заморозить JSON inputs и обе стороны expected; фактический иной результат сохранить.

| ID | Расписание и вход UTC | Гипотеза Java / Rust |
|---|---|---|
| ordinary | UTC, Mon 09–18, 2026-06-01T09:00–18:00Z | 32,400,000 / 32,400,000 ms |
| clip | То же, 09:30–10:15Z | 2,700,000 / 2,700,000 |
| weekend | UTC, Mon–Fri 09–18; 2026-06-05T17:00–06-08T10:00Z | 7,200,000 / 7,200,000 |
| holiday | UTC Mon09–18, holiday 2026-06-01; 09–18Z | 0 / 0 |
| nonhour-zone | Kathmandu Mon09–18, 2026-06-01T03:15–12:15Z | 32,400,000 / 32,400,000 |
| spring-elapsed | Berlin Sun01–04, 2026-03-29T00:00–02:00Z | 10,800,000 local / 7,200,000 elapsed |
| fall-elapsed | Berlin Sun01–04, 2026-10-24T23:00–10-25T03:00Z | 10,800,000 local / 14,400,000 elapsed |
| spring-gap-boundary | Berlin Sun02:30–04, 2026-03-29T00:00–03:00Z | 5,400,000 / calendar_boundary refusal |
| fall-fold-boundary | Berlin Sun02:30–04, 2026-10-24T23:00–10-25T04:00Z | 5,400,000 / calendar_boundary refusal |
| invalid-zone | Unknown/Nowhere | Java ZoneRulesException at construction / calendar_timezone |
| overnight-invalid | UTC Mon22–06, 2026-06-01T00:00–23:00Z | Source hypothesis −57,600,000 / calendar_policy; not supported business overlap |
| reversed | UTC Mon09–18, 2026-06-01T10:00–09:00Z | 0 / calendar_policy |
| precision-api | UTC Mon09–18, 2026-06-01T09:00:00–09:00:01.250Z | Main toMillis 1250 / 1250; separately observe upstream getDurationMillis hypothesis1251 |

Отрицательная длительность overnight и поведение getDurationMillis — именно проверяемые диагностические гипотезы, не уже установленный runtime defect. Не исправлять upstream, не нормализовать результат и не выдавать произвольный локальный календарь за Apromore.

CalendarModel хранит кэш holidayDates. Для каждой строки создавать новый настоящий builder/model; после вызова наблюдать публичную конфигурацию before/after, не изменять список holidays между вызовами и не делать вывод о корректной invalidation кэша. Исключения сохранять с точным классом/этапом. Защитный отказ Rust сравнивается отдельно от equality durations. Изменение Rust gap/fold/overnight политики в этот reference increment не требуется.

## Реалистичная поставка в этом окне

Предлагается после R4 сначала finite calendar reference (13 строк, ожидаемо 60–100 минут на adapter/freeze/admission/captured runs/independent comparison), затем при наличии ещё 60–100 минут расширить фильтры указанной восьмёркой. Перед обоими — отдельное согласование точного профиля и ручных гипотез. Не запускать оба потока native одновременно с Root Cargo-фазой; готовить источники параллельно, выполнять native в выделенных окнах.

Новые артефакты после отдельного GO: `fixtures/oracle-core-calendar/`, `tools/oracle/core-calendar-*`, отдельный Rust диагностический example и pure comparator у Root, private `.local/sprint19/service/calendar01`; для фильтров новые `fixtures/oracle-core-filter-extended/`, `tools/oracle/core-filter-extended-*`, private `filter01`. Старые S18 файлы и evidence остаются неизменными. Это только предлагаемые новые пути, сейчас они не создавались.

Для native нужны новые S19 wrapper deadline/SID/scope bindings и exact configuration QA review: S18 guard уже истёк и не переиспользуется обходом даты. Каждая JVM ≤180s, heap≤512MiB, stdout/stderr≤8MiB, Job assigned-before-GO, закрытые child/worker/native streams и actual exits. Service ≤2GiB logical AND actual allocation, free≥8GiB, общий потолок12GiB, freeze07:39:14Z. Нужны class/JAR/JDK/tzdb/input/source/executable pins, old5763/285 postreadback и независимый QA, публичная lossless числовая публикация/portable field replay.

Критерий завершения этого вклада: исполненный неизменённый API, все замороженные случаи с полными значениями/индексами/сохранением источника, честный журнал расхождений и независимо воспроизводимая конечная поставка. Календарные семантические различия не закрываются средним процентом совпадений. Полные R5-01/02, conversions и miner автоматически завершёнными не становятся.
