# Sprint06 — XES reference

Лимит четыре часа: 2026-10-11 02:04:15–06:04:15 UTC. S6-P1 принят пятью независимыми голосами. Независимая техническая приёмка ограниченного oracle подтверждена на C2. Пять фактических голосов приняли точное предложение S6-F1; итоговый CI проверен, PR6 объединён. Независимая проверка публичной доставки описана ниже.

Настоящие неизменённые OpenXES parser и LogParser XLog overload ApromoreCore запускаются без заглушек. Feasibility подтверждён до02:48:15; холодная сборка также воспроизведена. 134 upstream OpenXES исходника закреплены Git blob/SHA256, selective genuine closure129 классов. Public lock/standalone build helper получает primary source/dependency bytes, проверяет size/SHA/blob, выполняет compile/version/probe и сохраняет manifest.

Заморожены десять новых примеров до исполнения. Ручной Rust контракт прошёл: source/timestamp order, stable ties, UTC-equivalent offsets, lifecycle, отсутствующее/некорректное время, неправильный тип, duplicate semantic key, Unicode, empty trace и submillisecond precision. Девять Java примеров завершились exit0; invalid-time exit1 с upstream `EmptyStackException` явно сохранён. Три различия: принятие string timestamp, последнее duplicate-name и миллисекундная точность Java. [Точный контракт и воспроизведение](XES_ORACLE.md).

Шесть прежних входов сохранены без изменения и выполнены через настоящий XES parser; точный принятый0.5 EXE `4DA47C60DA169B2B0D659E4583A72EA5E17DBCE18B83E28B8923B2DF1CDAF98A` прошёл прежние ручные/новые actual consumer comparisons в отдельном ephemeral процессе. Это не запись в пользовательские проекты и не перенос приёмки на новую сборку.

Production src/Cargo/Windows helpers не изменены; новая Windows-упаковка не требуется. Поставка0.5 остаётся действующей. Новые example/tools служат developer conformance, не входят в приложение. Полные R2–R5, Portal/service validateLog, calendars/DST и miner/BPMN quality остаются частичными или непроверенными. DISK01 и native5 backup остаются открытыми.

## Матрица кандидата

| Критерий | Доказательство и состояние |
|---|---|
| A01 настоящий parser/consumer | build02 actual probe0; standalone cold04 fetch/compile/version/probe0, full313file proof |
| A02 immutable corpus | SHA8ebdb55f3a6a8c585865014c206d92be3d11e314925c52c1e7c6665ed9d14ac4; QA pre-run literal review |
| A03 actual outputs/Rust | Независимые16 genuine Java executions (15exit0/invaliddate1),20Rust modes и принятый0.5 six replay: scoped PASS |
| A04 time/lifecycle/negative | literal expectations + separate source/time/error policies, actual upstream exception and three divergences |
| A05 independent QA/auditors | ExactC2 QA/replay, public safe export, TD scoped ACCEPT и пять отдельных финальных FOR |
| A06 public PR/CI | Итоговый H CI успешен; PR6 merged, полный публичный архив и сохранность прежних установок независимо проверены |

## Ход и ограничения аудита

Начальные source/clock/Git reads доступны только в tool outputs. Первое исполнение helper было недоступно из-за среды sandbox; разрешённый elevated путь сработал. Один guessed historical registry path отсутствовал, не является runtime ошибкой. Build01 выявил missing SLF4J; dependency закреплён по primary BOM, build02 прошёл. Cold03 отказал из-за неверно прочитанного tree identity; corrected primary commit→tree binding, cold04 прошёл. Run02 отказал на несовпадении формата manifest status; необязательное поле исправлено при сохранении обязательных hashes; новый run03 прошёл.

Старые private ACL raw-файлы первых попыток частично недоступны; audit coverage не выдаёт это за полный captured success. Independent cold313 files полностью hashed,134upstream blobs и504JDKfiles/noextras проверены. QA выявил verification gaps: независимые имена/кардинальности/precision/consumer counters и timestamp type/value; adapters усилены, прежние результаты сохранены. Оба QA-S6-01/02 закрыты независимым exactC2 replay. Coverage:502доступных/409565B,10недоступных явно перечислены. Работа с реальными пользовательскими БД, cleanup/backup и package/install в этом спринте not-in-run.

## Точные доказательства

C1 source `b0dcf126f076714d8571f65c759fa39591b4aebd`, Git archive SHA15478C325844FE3235129E71A4F880136D565FF14870940799E9DF7EF614A4D7; observer EXE E7C86243A7EB5DA6D55401E977839CF23D2D07B1BFF9A4E60672861B04206E3B. C2 `d0665a40f5389ce901100e2a20a7aed32f791c67` меняет только comparator и его описание; src/examples/Cargo/build helper/lock идентичны C1. Final documentary head отдельно от этих исполняемых доказательств.

Независимый QA: [position](../flw/evidence/sprint-06-qa-c2-position.md), JSON SHA466999F2B3C34385BB80A7EAD5D8BC3A8BA39FB3D3CCC1D955737EDC023C5FC4; [coverage](../flw/evidence/sprint-06-qa-c2-coverage.json), SHA95C187191DF9BC4912334FCE3696A2B20C007DCA37CAC62E2CAA5B03DF40CDAF. Public safe projection audit CAD97CFE36AE81AAA1B11BFCD496FD50AAEE0B502C885A271B09F92ABD2F546B.

Фактические безопасные результаты: [10 XES reference](../fixtures/oracle-xes/reference-results.json), [20 Rust modes](../fixtures/oracle-xes/rust-comparison.json), [шесть прежних регрессий](../fixtures/oracle-xes/original-six-results.json). Полные upstream source/jars/raw stderr остаются приватными; original raw report SHA указаны в projections. Local clippy0 и обычные Rust tests0;13PostgreSQL scenarios ignored/not-in-run для evidence-only sprint. Provenance guards5PASS; final CI проверяет тот же скрипт.

[Независимый TD](../flw/evidence/sprint-06-td-final.md), SHAB57BCEC988C881C4E0606B7336E9C6FE5F0B291943EB6B7C8EDC0398BA14DC5C, подтверждает закрытие verification причин в выбранном контракте. [Source equivalence](../flw/evidence/sprint-06-source-equivalence.json): production diff0 от compiled55e8 через принятую35f0 доC2,70ordinary tests PASS/13ignored. Raw-хешированные Sprint06 evidence сохраняют исходные байты через `.gitattributes -text`; line-ending normalization не меняет доказательства при публикации.

## Публичная доставка и завершение

Техническая приёмка завершена 2026-10-11T02:47:17.158138+00:00; фактическая длительность до фиксации отчёта 43 минут при лимите четыре часа. Итоговое решение человека остаётся отдельным.

[Совет S6-F1](../flw/evidence/sprint-06-council-final.json): пять фактических FOR по SHA256 DB408476869CC63D1DBDBA0204D4333BBADDBC0B93B7D284F2881EF9E1BE3D92. Ранний проект A1EF5327 отозван до внешних голосов; учитывается только окончательный документ. Root проверяет хеш своего предложения и явный FOR, остальные голоса — также привязку к точному SHA; самохеш не требуется внутри собственного файла.

[PR6](https://github.com/erkevibe/process-intelligence-rs/pull/6) объединён из проверенного H `2fde54866d1e15be17b8486fdcdb83658ba46348` в M `5404a62a48b9169dce4d815cdfcefa024bb637b4` при неизменном base `35f0e783ad68d815f32977e3094088d42b28858e`. [Независимый итоговый CI](../flw/evidence/sprint-06-qa-final-ci.md): два успешных прогона, push checkout H и отдельный PR synthetic merge. Полностью прочитаны 26 доступных файлов/321361 байт; 70 обычных тестов, пять provenance guards, fmt/clippy/release/health прошли. 13 PostgreSQL сценариев пропущены; Java oracle исполнен отдельно локально.

[Независимая проверка доставки](../flw/evidence/sprint-06-qa-delivery.md): анонимный исходный архив по M, SHA256 C8F21B9251CCE4272C27B5BB8884948E536449E81BCEE37133959C77876FBD2F; все 430 файлов и Git blobs совпадают, безопасные результаты совпадают. Прежние пять установок проверены только чтением, EXE/PID/04–05 ZIP сохранены. Новая версия Windows не выпущена; действующая 0.5 остаётся прежней.

Первый локальный вызов verifier остановился до Python из-за неверных разделителей пути executable; путь исправлен, уже анонимно скачанный архив сохранён, второй вызов прошёл. Проверка голосов ранее отказала до merge из-за требования самохеша внутри Root proposal; исправлена только эта логически невозможная проверка, обязательные файловые хеши сохранены. Эти ошибки не выдаются за успешные первые попытки. Финальная фиксация меняет только документы и доказательства, исполняемый исходник соответствует проверенному H.

Следующий предметный шаг — настоящий контракт service-import `validateLog` на малом заранее замороженном корпусе: фильтрация отсутствующих имени/времени, lifecycle и пустых трасс. До изменения Rust политика различий должна быть определена. Управляемая очистка legacy-копии остаётся отдельным эксплуатационным спринтом с новым restore/rollback и проверкой прерывания.

[Независимый аудит после доставки](../flw/evidence/sprint-06-td-delivery.md): scoped ACCEPT, SHA256 A9744BFF754331D8D2B3385FD7FA44CC4127C3978D29A0FB194C244FE8DC0F74. История исправлений и границы доказательств сохранены.
