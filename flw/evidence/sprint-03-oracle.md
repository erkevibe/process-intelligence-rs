# Sprint03 — фактический узкий oracle, PM evidence

Автор /root/pm_final, существующее место PM; это реализация harness и предварительная проверка, не независимая QA-приёмка. Adopted S3-P1 raw SHA256 A33E3CE16F8E585AB288162BBCD684A054D183FF4B1F52266CE41A218746FB7F. Координатор уточнил фактическое принятие 11:42:08 UTC; раннее сообщение 11:49 было ошибкой времени. Лимит 45 минут относится к действительному принятию. Реальный reference уже выполнен до проверки часов 11:49:59 UTC; диагностический лимит не исчерпан. Подготовка входит в общий спринт 11:37:57–19:37:57 UTC.

## Исполненный компонент и идентичность

- Настоящий ApromoreCore commit bbf24dfd43e72d6992392465f875a4367cbe792b: неизменённые SplitMiner LogParser.getSimpleLog(String) и SimpleLog. Не Portal и не полный SplitMiner.
- Private source `.local/sprint03/oracle/LogParser.java` SHA256 14F30EEE8C2099DF3ACF04C12CA2CB462B4FD7B6419B614309F8AE2DB177DFA0; Git blob 172d0161fc35cbb7e45a8f7f816ebb4bc4110499.
- SimpleLog.java SHA256 B4726AFE80B4536AC5B27A5383A63A3A6D79CC9DA2076078406AECF752EADFC7; Git blob 0a60acb52645d492a694d8cfd15f9e95e28440b6.
- LICENSE SHA256 E3A994D82E644B03A792A930F574002658412F62407F5FEE083F2555C5F23118; Git blob 0a041280bd00a9d068f503b8ee7ce35214bd24a1. Реальные headers/root LICENSE: LGPL3, headers допускают later. Чужой source/classes не включаются в MIT runtime или публичный repository.
- Eclipse Temurin JDK 11.0.32.1+1, scoped private extraction, global PATH не менялся. Actual ZIP SHA256 D5008F02174C1AD21C10407CBF104815CB390EC4C263D53946E8D0507D7A77F9 совпал с официальным Adoptium metadata. Pinned URL/version/hash в tools/oracle/reference.lock.json, полный metadata private `jdk-metadata.json`, actual version captured per attempt.
- Download01 timeout180s с 166385208/199461714 байт. Resume02 скачал остаток, checksum verified. Distinct `.local/logs/s3-oracle-jdk-download.*.log` и `s3-oracle-jdk-resume02.*.log`; первоначальная ошибка сохранена. Это изменённый механизм resume, не повтор полного скачивания.
- Byte identity sources независимо проверена SHA1 Git blob против `.local/sprint03/legacy-tree.json` закреплённого commit: все три совпали. Public fetch script проверяет fixed SHA256; никогда не принимает изменённый source молча.

## Corpus, запуск и результаты

Шесть literals fixtures/oracle/corpus.json SHA256 **6C0ADE912A2C6E9DB989ECD0C81E2B4C5FE3C39D2FA6544837497976F5A6FC5B**; XES/text hashes по каждому примеру в manifest. Hand expected arithmetic написал PM до reference; QA отдельно пересчитал. Frozen literals после этого не менялись.

| Пример | cases | events (ручной/Rust) | activities | variants |
|---|---:|---:|---:|---:|
| alternatives | 3 | 6 | 3 | 2 |
| self-loop | 2 | 3 | 1 | 2 |
| empty-trace | 2 | 1 | 1 | 2 |
| unicode | 2 | 4 | 2 | 2 |
| lifecycle | 1 | 3 | 2 | 1 |
| timestamp-order, source | 1 | 3 | 3 | 1 |

Actual source compiled build-01; javac upstream unchecked warnings captured, no error. Compile-only OpenXES types satisfy UNUSED XLog signatures and throw from constructors/methods. Harness invokes only actual String overload. Earlier exploratory compile/classes and reference-01/02 retained; final guarded reference-03 records actual runtime/versionstderr/archive and class hashes. Each fixture JVM exit0; six cases/activities/variants match literal expected. Public safe `fixtures/oracle/reference-results.json` SHA256 **5A7D3269647AED5DED752FB495A572770BC81A600321A6AAF374DD4F3CAD8D0A** is copied from actual `.local/sprint03/oracle/reference-03/results.json`.

Full stopped private coverage: build-01 compile.stdout/stderr, java-version.stdout/stderr; reference-03 runtime.stdout/stderr plus six `<fixture>.stdout.log`/stderr and results.json. Wrapper logs `.local/logs/s3-oracle-reference03.stdout.log`/stderr. These are captured attempts, not a fabricated earlier control log. Earlier failure attempts remain separate. No growing log is claimed final.

### Rust executions, preliminary only

Comparator spawns a fresh own ephemeral process/free port, uploads same XES bytes through native HTTP, checks exported source hash, decodes IDs back to labels, checks each count/variant/DFG against hand literals and selected fields against actual legacy. Raw upload HTML/exports/process stdout/stderr preserved in each private attempt. Own child is stopped; live R1/user applications and PG not used.

- Accepted old0.2 EXE E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E: rust-baseline-03 all6 comparisons true, report SHA256 C0EE4B073489B8DBB1B150F28F59538A625670DB69FC1CA78B956128A98AB0B8, PID3928/port51980 stopped. Historical baseline validates harness, not S3 acceptance.
- Unfrozen **draft0.3** target/debug/process-intelligence-rs.exe actual SHA256 **E19C25CD7AEC44106BD398AA4403DCAB33286BF82EBE2D80D6A329C473F9EA76**: rust-draft04 all6 comparisons true, report `.local/sprint03/oracle/rust-draft04/comparison.json` SHA256 **2282D35D6F986EAE5E14DF5C7EC56356FE29BC4A3B38DB5495849F4AA45DC5A9**, PID34220/port51432 stopped. Wrapper `.local/logs/s3-oracle-rust-draft04.stdout.log`/stderr. Source not frozen: this is draft evidence only. Final exact EXE/package requires fresh independent QA replay; these results do not transfer.

QA reported independent actual replay reference-qa-01 exit0 and independent six manual counts/variants/DFG/hex-adapter/hash checks; ownership and final QA verdict remain its own evidence, not PM's.

### Draft release05, отдельный настоящий replay

По новому поручению Root повторён comparator на unfrozen target/release/process-intelligence-rs.exe actual SHA256 **1158AD54E387316507824C97194601B920EB1C2795E2933D9BB970EAA7ECA2C7**. Все шесть ручных counts/events/activity counts/variants/DFG и три narrow actual legacy fields совпали; comparator exit0. Private `.local/sprint03/oracle/rust-release05/comparison.json` SHA256 **03AD3D415B2FD42C5BF6BC909CEB296A16B11574EB6DCA290155949C7B3A67BE**, ownPID46928/freeport49725, own child остановлен. Новый каталог сохраняет каждый import HTML/export, process stdout/stderr; wrapper `.local/logs/s3-oracle-rust-release05.stdout.log`/stderr отдельные, прежние attempts не перезаписаны. Frozen corpus/reference bytes и runtime source PM не изменял.

Это всё ещё draft replay, не exact finalfreeze, не QA product acceptance и не Councilresume. Root сообщил две самостоятельные operational STOP-области: terminalcancel/error до durablecommit и supported153MB debug reopen при10s transaction CPUvalidation. PM их исполнение здесь не проверял; release-profile oracle использует ephemeral mode и не доказывает исправления PG/jobs/reopen. Эти STOP не закрываются шестью mining примерами. Нужны actual независимый QA, точная targeted резолюция и TD closure; старый голос bootstrap resume к ним не переносится.

## Explicit boundary and operational position

XES→trace text is an original external adapter: source event order, concept:name classifier, each-event lifecycle, reversible hex labels, one frequency per trace. Reference sees normalized text, so legacy importer/defaults/lifecycle joining/timestamp sorting are **UNVERIFIED**. Hand timestamp_expected for sixth fixture is a separate literal, not executed legacy normalization. Real text overload getTotalEvents returns -1: retained, never replaced with invented event count. Legacy DFG is not executed; events/activity frequencies/DFG above belong only to Rust versus hand expected. No Portal, full Apromore compatibility, percentage filtering or discovery quality claim.

Read-only PM snapshot current storage/migrations/bootstrap: draft has lease before DDL, additive atomic ledger/constraint, explicit5s connect/statement2s lock10s transaction15s response, failclosed uncertain outcome and no mutation retry. These match planned direction but require QA actual faults/upgrade/WAL/restore, not source-only PASS. Ключи вне auth/repository/* были подняты PM как вопрос контракта. Root уточнил intentional generic Database API: непризнанные opaque KV (в том числе qa/*) сохраняются без преобразования, не считаются совместимыми app DTO; docs/DATABASE_RECOVERY.md фиксирует эту границу. Для признанных auth/repository DTO unknown fields должны отклоняться до ledger. Это уточнение не меняет immutable A05 catalog/known-state criteria; QA отдельно проверяет nested unknown. Future schema/checksum/constraint checks need independent negatives. Bootstrap recovery likewise requires controlled fresh nativePS5 phases; no oracle result offsets these mandatory A03–09. Final90min and live3010/3000 preservation remain mandatory.
