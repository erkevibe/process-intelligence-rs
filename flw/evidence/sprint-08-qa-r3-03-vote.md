# Sprint08 F2 — фактический независимый голос QA

UTC: 2026-10-11T06:28:39.7746891+00:00

Голос: **FOR**.

Точная полностью прочитанная резолюция: sprint-08-r3-03-proposal.md, RAW SHA256 **583A706CEC2BC3C82FE7624D6BD9D88428095C69E05C9BBAFECF2BF6B645A150**. Хеш независимо вычислен и совпал. Это новый голос; прежние F1 и targeted-resume голоса не перенесены.

Принимаю только исходный конечный **R3-03 «Сохранность, миграции и развёртывание»**, без изменения определения в SPRINT_08_SCOPE.md (SHA256 CA6E7470FF31FA3493E00578B4C12755AE28AD9681C47701DD7C8CF70C4364B0). Основание: собственные фактические frozen проверки миграции полного старого корпуса, interruption/resume, полного backup/new restore, RBAC, app/job и PostgreSQL WAL recovery; новые current-v2 отрицательные проверки future ledger/checksum/envelope с полным SQL conservation; самостоятельные public download/manifest/cold install/protected read-only проверки и завершённый bounded completion-CI аудит. Независимые TD отчёты F41D606AE711E9F92265158C0BA482A0318DCF4FB3A7C3A4B7E2D23EE5192F13 и 5D8971B88AD98BCE7AB74B3AE2FBB146D2CCA772F7A4728E01D90B79E669EBB5 полностью прочитаны и их текущие хеши проверены.

Предмет голоса связан с runtime C281d13ddc8bb1813545c9ffe7fa92e8f49aaa6e0, EXE95D1340D2C8C5B4BCFD835F4A53BEE7A67CE98242685AC973F775BD6747DD778 и ZIP4AE712B07E58B23F3A3FB53D8CAF5EED83BB9E9AE5EC49A5CFAA19C85B5A2759/57100032B. Completion CI38117713382 на H2 42090059c5ee8cd22a4ce46021f209812b7bbdbc фактически SUCCESS; Linux CI не исполняет заявленные Windows/Java/PG acceptance проверки, 14 ignored не объявлены выполненными.

Все остальные 14 строк остаются **OPEN/BLOCKED**, включая R2-04 с отсутствующей C06 dates/state, full R3 и full R2–R5 не принимаются. Не обещаю supported downgrade, HA/general DR, любые будущие форматы или полную совместимость legacy service. PS7 backup и native PS5 Start различаются; native PS5 full backup остаётся UNVERIFIED. Protected identity/health проверка не является SQL или физической побайтовой аттестацией пользовательских БД.

Сохранены первоначальные failed verifier/tool attempts, stale labels с отдельным runtime-binding supplement, неполные child identity/exit capture и границы доступных журналов. Эти ограничения не скрыты и не заменены пустым PASS. В рамках данного голосования новых runtime проверок, SQL пользовательских БД или правок реализации не выполнялось. После решения допустимы только заявленные metadata-only документы и отдельный CI; runtime/package/tag остаются прежними.