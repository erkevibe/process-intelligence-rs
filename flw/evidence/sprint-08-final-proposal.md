# Sprint08 F1 — точное предложение Совету

Предлагается принять **выбранный локально проверенный increment версии 0.6** и разрешить его guarded merge и публичную поставку. Полные R2–R5 не закрываются; все 15 исходных критериев сохраняются OPEN/BLOCKED согласно исходной матрице и текущему отчёту. Это не голос автора за отсутствующие доказательства.

## Неизменные идентификаторы

- Runtime source C: `281d13ddc8bb1813545c9ffe7fa92e8f49aaa6e0`.
- Audit/documentation head H: `ae612373c95a4179ffd94ccbfbc4004db600edea`.
- Ожидаемая база main: `82bd92bd43717310dec71ac2a054252b8d14c4f7`; PR8, merge method merge с expected head H. Проверить фактических родителей и отсутствие runtime/tool/test/Cargo изменений C→merge.
- Windows EXE SHA256: `95D1340D2C8C5B4BCFD835F4A53BEE7A67CE98242685AC973F775BD6747DD778`.
- Windows ZIP SHA256: `4AE712B07E58B23F3A3FB53D8CAF5EED83BB9E9AE5EC49A5CFAA19C85B5A2759`; 57 100 032 байта.
- Manifest SHA256: `4BBB8EFC53ADCDC0A38B380CA8ACA627E9C64A573B6947BE803899E1EA2E5C05`; 1 726 records /1 727 ZIP files.
- Тег `v0.6.0` закрепить именно за C, а не за H/merge. ZIP не переупаковывать. Release notes отдельно закрепляют актуальные документы H и последующий metadata-only completion report.
- H report SHA256: `E1BB7D8D3BADA3F7D528B872A067F9A25509A8087C5299D4219C2BCF6A6A37FD`; runtime guide SHA256 `39192540C80FC6384F13738F053C69BD8EB91739954AAB2BD72A163FC228E93D`.

## Независимые основания

- QA JSON `6F6F925E96C661A1CA2757DE71F38A5C5C0349B4B22A79A64AA79297319CA226`, review `EF138D94AD24ABE1871FC712E2E2959330544FEC9B1CE4BBD96F39223FA75D7B`: exact native cold package, настоящие HTTP/PG/fault/restart/backup/migration/retention/limits/rights проверки. Только семь применимых PG tests реально исполнены, шесть v1-specific неприменимы, один cache test NOT-IN-RUN.
- TD final `B736CBDAE5B0D36901F026704E6952F277EB0DEA497ABDBC4AD3D632EDC1B68F`: full named inputs/logs/source/package и source-equivalent календарь/Alpha/weak-owner наблюдатели, отдельные EXE и границы не скрыты.
- QA binding supplement `F8E773D77FE6BB0B5602DA73BD3164D62B53703CE0517A2E85D7903DEBE54A17`, independent TD binding `C8E1617D49B17830D904EFF568A4282A3DB80358008E10EF95D3EB2E432D3F4E`: исходные stale d29/D4/no-native labels сохранены, фактические requests/launches/paths связывают их с95D. Мгновенный снимок creation/hash одного restart child отсутствует; не выдуман.
- Customer exact native browser `8996E4E4FFE60960A6B4D54DA8A3813587AECD1BD593043B279967EE8A4C5CFB`: семь актуальных проверок интерфейса; сценарии серверных отказов/аварий — отдельные QA доказательства.
- Final H CI push38116367384 и PR38116369614 actualSUCCESS. Root full14 logs report `80349834CEF7640EDA73B4C1DB2A384F1B1D8E5259BC0FD56680CF019D5652A1`; independent TD `80BBFAA74C4D93AEDDE2514B2F4D0B9B2273CD3093319A9CDCF9D727EFCCAED4`. 93 ordinaryPASS/14ignored, guards5+7, pinned1.99/fmt/clippy/release/ephemeral health; не PG/Java/packageCI.
- Independent anonymous sourceH611 Git blobs `8CC9A7D68CDC31017F67DBEDC0F705BB54D6E9D77F93D94FEDFE4DE730AE60F1`; C→H runtime/tools/tests/Cargo diff empty.
- Protected read-only finalpre capture `6C257832E89C3A059423C6B1F67B3C2F351C47B26066ACB773EC27E22CBE4A6C`, independent QA review `6F58820A2A51CB670E9F9A462827A60E5198A9AA041DAD1EE5E2CC5E917C66A9`: пять приложений/шесть PG процессов и04/05ZIP. Только process identity/health/artifact, не fullDB-byte conservation.
- RESTORE01 и AUDIT-PID01 причины закрыты отдельными фактическими Council решениями; их закрытие не заменяет это новое голосование.

## Принятый объём и обязательные границы

Opt-in XES preview/consent с точным raw/provenance/history; native folders/rename/archive/unarchive/current-auth gate; bounded successful audit; IANA finite UTC/DST/refusal contract; standalone genuine bounded Alpha/PetriNet/PNML. Source-equivalent независимые observers не объявляются packetEXE. Strict import сохранён.

Fullservice/SplitMiner dependencies BLOCKED. Полные attrs/classifiers/order/lifecycle, durable preconfirm operation discovery/lost-successful-COMMIT-ACK, generic audit policy/result, permanent project deletion, destructive cleanup/DISK01, wider BPMN/loops/noise/measured quality, legacy filters/Calendar/lifecycle/conversions остаются OPEN. No overnight/downgrade/nativePS5fullbackup/generalRAM/bit-reproducibility/allchildidentity claims. Preview5min/restart expiry/manual fullreport+URL UUID/fullSHA reconciliation/retention512 disclosed. Исторический actor не удостоверяет личность.

## Поставка не может быть объявлена завершённой до A07

После фактического решения: guarded PR merge; release0.6 immutable ZIP/checksum на C; независимое anonymous full public ZIP download и сверка всех manifest bytes; свежая отдельная установка из публичного пакета; новая пользовательская установка Root на3061/5441 без тестовых аккаунтов, first setup пользователем; postpublication protected readonly snapshot и независимая сверка; фактические main/tag/release asset IDs/bytes/parents; актуальный итоговый отчёт и metadata-only completion commit/CI.

Все эти шаги обязательны, не waived голосами. При несовпадении source/package/unsafe mutation/провале mandatory QA — STOP и соответствующая независимая процедура, а не автоматическое принятие. Никаких изменений старых данных, удаления, миграции или остановки прежних установок. Root может дополнять после решения только документы, доказательства и release notes фактическими результатами; runtime/tool/test/Cargo изменения требуют нового кандидата и приёмки.

Пять фиксированных голосующих: Root, PM, Customer, QA/ProcessLogAuditor, TechnicalDebt/SkillManager. Emotional — вне голосования. Каждый голос относится к полному SHA256 этого нового предложения; прежние голоса не переносятся. Решение >половины фиксированного состава с фактическим UTC, обязательные QA/TD ограничения остаются действующими. Состояние до голосов: PENDING.
