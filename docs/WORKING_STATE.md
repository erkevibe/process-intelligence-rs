# Рабочее состояние ProcessMining

Обновлено 24 октября 2026, 11:20 UTC. Рабочая ветка:
`codex/sprint-26-durable-quality`. Пользователь поручил работать восемь часов:
09:14:49–17:14:49 UTC (до 22:14:49 Asia/Qyzylorda), затем зафиксировать итог.
Цель активна; после P1 продолжать P2 из `DEVELOPMENT_PLAN.md`.

## Принятая основа

PR38 независимо проверен, исправлен P2: Datastar иногда завершает HTTP-отказ
без patch, оставляя старую панель в ожидании. Исправление `bf3c66f` прошло обе
CI; PR38 слит в main: `4ac5d20f93d57d8f3657ba75357ccbdc17e5d304`.
История восстановления предыдущих сеансов — `SPRINT_25_PREVIEW_REPORT.md` и
`../evidence/sprint25/preview/`. Не считать отсутствие старого финального
receipt успешной остановкой: свежая `resume-live05` закрыла этот пробел отдельно.

## Текущий кандидат 0.9.0

Сохраняемые входы/отчёты, JobStore с общими местами, отмена, interrupted после
перезапуска, идемпотентные ключи, HTML/SSE, JSON экспорт и офлайн-проверяющий.
Явная миграция v3→v4, старый бинарник отказывает v4 до записи. Restore заново
проверяет недоверенные численные отчёты с общим кооперативным deadline и CPU
допуском. В узких панелях доступна навигация. Это ещё не принятый релиз.
Контракт: `QUALITY_JOBS_CONTRACT.md`, отчёт: `SPRINT_26_REPORT.md`.

Приватные материалы `.local/sprint21/root/sprint26/` содержат тестовые cookie,
пароли и сырые ответы. Не публиковать их целиком. Публичные компактные записи:
`../evidence/sprint26/durable-quality/local-checks.json`.

- `verify06/proof.json`: 8 коротких тестов, Clippy all-targets, app build — pass.
- `runtime02/proof.json`: PostgreSQL core, populated migration, old-binary refusal
  без изменений полного снимка, CLI, 101 native HTTP, backup/restore и coherent
  numerical forgery refusal; browser report/reload/retry/download; clean closure.
- `restart01/proof.json`: настоящая committed nonterminal задача захвачена SQL-lock,
  broker убил только app-before, app-live отметил interrupted; входы идентичны,
  прежний отчёт побайтно тот же, явный retry успешен. Fresh PG core проверил
  исправление ID импорта с настоящей sequence. Новая диагностика v4 прошла.
  Браузер: видимая навигация, отмена job-41 и сохранение отмены после reload,
  ошибок консоли нет. Все процессы закрыты штатным протоколом, pidfile отсутствует.
- Независимый reviewer проверил runtime02: 18 capture/36 потоков, 101 ответ,
  source pins; исправлены replay после удаления, active_jobs, forged restore.
  Последний P2 про namespace импорта исправлен и проверен в restart01.
- `verify05` отказал на resource_sample_timeout; сборка была остановлена и не
  засчитывается. Повтор `verify06` прошёл без изменения защитных пределов.

## Следом

1. `full02` завершил полный cargo test: 195 passed, 0 failed, 27 ignored.
   `full01` остановлен capacity guard; штатный cargo clean -p убрал generated
   artifacts, база/отчёты/старый baseline сохранены. Rebuild07 завершил native
   build; внешняя оболочка сообщила unset LASTEXITCODE, сам closed proof успешен.
   Побайтная воспроизводимость нового бинарника с прежним не заявляется.
2. PR39: https://github.com/erkevibe/process-intelligence-rs/pull/39.
   Независимое локальное P1 ревью без блокеров. 22e0604 CI остановился на
   historical kit, которому нужен frozen0.8.2 вместо свежего0.9.0. 547dede
   исправил только пути, pins сохранены; локальный selfcheck-frozen01 PASS.
   Затем CI выявил случайный личный проект editor в тесте: b93dbcd явно
   переключает на shared перед проверкой revocation, продукт не изменён.
   verify08 и native core04 (fresh DB, clean closure) прошли; reviewer сверил
   все receipts. CI b93dbcd прошёл проверки и сейчас собирает Linux release.
   Итоговые docs/evidence требуют собственного CI commit перед merge.
3. P2 — отдельная ветка `codex/sprint-27-miner-experiment`: e7522e6 закрепил
   MINER_EXPERIMENT.md/corpus до новых запусков; f530db2 сохранил непроверенный
   isolated example miner_compare.rs. Прототип преобразования Alpha+++ Petri→BPMN,
   UUID colour refinement отказывает неоднозначной симметрии; тесты и компиляция
   впереди. Не включать P2 в PR39. После завершения P1 вернуться в P2 branch,
   включить последние P1 fixes. Подготовлены только исходники, miner ещё не запускался.
## Ограничения рабочей среды

Пользовательский сервис 3131 не трогать. Собственный PostgreSQL —
`.local/sprint21/root/pgdata11`, порт55449; app fixture3147. Соблюдать existing
resource guards и private ACL. Не удалять postmaster.pid/WAL вручную.
Не изменять pinned источники во время сборки или runtime-сеанса.
Не закрывать последнюю вкладку IAB: прежние два сбоя следовали сразу после close,
причина окончательно не доказана. Текущий durableTab оставлен для дальнейшей QA.
