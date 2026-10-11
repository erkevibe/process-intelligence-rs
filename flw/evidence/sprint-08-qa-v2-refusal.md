# Sprint08 — независимые currentv2 отказы

Три finite negative cases прошли на новых собственных PostgreSQL5443 копиях, source281d13ddc8bb1813545c9ffe7fa92e8f49aaa6e0 / EXE95D1340D2C8C5B4BCFD835F4A53BEE7A67CE98242685AC973F775BD6747DD778. Ожидания зафиксированы ДО исполнения contract589A9676F877226B05D372882EE3D9A05970CFDE1B451ED876423043F8D714CF, без переноса старого v1 ignoredtest.

- ledger version2→3: child47428 nativeexit1, controlled unsupported-schema message, полное SQL state до/после одинаково.
- ledger2 checksum→64нулей: child16496 nativeexit1, controlled schema/data unsupported message, полное SQL state одинаково.
- source_envelope_version1→2: отдельный app49996creation06:19:37.904899/exact95D metadata startup200; после authlogin, ДО before fingerprint, actualGET original и import-history дали422 JSONrepository_corrupt06:19:38.456–474. Исходный XML не отдан, SQL unchanged.

Использованы три actual pg_dump/pg_restore копии нового собственного publicQA журнала с genuineconfirmed envelope. Основная copy-source БД process_intelligence5443 также осталась полностью прежней. Сравнение охватывает все application KV/header/record values+versions черезSHA, ledger/markers/sequence и catalogcolumns/constraints/indexdefs. Authlogin состоялся до before; никаких auth/projectopen writes в refusal interval. Старые binaries не запускались на новом формате, пользовательские/защищённые ресурсы не затронуты.

После успешных трёх assertions первый helper завершился1 из-за guessed nonexistent pwsh.exe пути в finallycleanup. Исходный failure.json/completed3, actualstderr и nativeexits сохранены. Отдельная исправленная cleanup проверила listener3064/CIM/path/hash и остановила ТОЛЬКО свойchild49996; последующий Nodecontinuation завершился0 и read-only сравнил sourcebefore/after. Негативные cases не повторялись. Forced cleanup не названа успешным startup exit.

Safe JSON sprint-08-qa-v2-refusal.json содержит84 полных selected input fingerprints. Этот отчёт закрывает только finite вопрос executable unknown-version/checksum/envelope refusal; сам по себе не является голосом F2, закрытием всего R3 или доказательством fullservice/parity/physical PG disk bytes. Более широкие R3-03 основания — отдельные ранее принятые migration/backup/fault/recovery/delivery proofs. CompletionCI остаётся отдельным gate.
