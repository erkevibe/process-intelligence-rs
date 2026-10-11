# Sprint10: SQL5, приёмка lifecycle/audit и поставка

Точное предложение Совету. Восемь часов: 11 октября 2026, 15:08–23:08 UTC. Metadata base 05d4c8005b66278cde08b53f20388e5497bde5d9, ветка codex/sprint-10. До реальных голосов это предложение, не принятое решение и не PASS.

## Цель и неизменные условия

Закрыть настоящий SQL5 на неизменном запросе полного cleanup corpus, завершить проверяемый crosswalk исходных R3-01/R3-02 и выполнить принятую публичную поставку только при фактически пройденных воротах. R3-04/DISK01 требуют всей исходной матрицы, не одного тайм-аута. Исходные определения из SPRINT_08_SCOPE.md и SPRINT_09_SPECIFICATION.md сохраняются. Enterprise readiness и полное R2–R5 не входят в обещанный результат.

Начальные диагностики подтвердили 5s/57014 и обработку ошибки, но использовали pg_sleep/test-only SQL substitution: они не закрывают настоящий SQL5. Неизменный runtime b4edef34b083d1cb7737cf648f1c051eeb94127a, EXE 7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195. Sprint09 C1 отклонён; C2 доказательства переносятся только по отдельному source-equivalence/case crosswalk, без blanket PASS.

## Ресурсы и безопасность

Новый приватный D:/CodexProcessMining/Sprint10-20261011-150800, которого сейчас нет. Перед созданием: canonical target/ancestor no-reparse, current SID, отсутствие старого каталога и порта, D не менее 10 GiB. Только новое поддерево получает защищённый ACL; чужие файлы и ACL предков не меняются. Полные source/verification базы и тяжёлые снимки на D, отдельный новый PG18.6 на loopback 5460. Очередной большой этап разрешён только при достаточном измеренном headroom; копии/снимки не сокращаются.

Распаковать точный существующий Windows ZIP EDACC3B836B5660439FFAA684A3D92451512731ADD9AAE89F0703A6E400C975A, проверить весь manifest/file set/SHA/length/no-reparse. Штатные helpers исполняются из новой D-установки. CLI cwd — эта новая установка, canonical .local с отдельно проверенными archive/manifest/plan/SID; guard private_path не меняется, junction не используется. Исходный C archive копируется полностью с PRE/POST SHA, новый source backup создаётся штатно внутри D .local. Никакого удаления прежних кешей, архивов, билдов, сырой доказательной базы или пользовательских файлов.

Действующая 0.6.1 и все прежние установки сохраняются. Никаких login/SQL/config/stop/cleanup в них. Перед и после этапа — именованная readonly process/path/creation/SHA/health/archive проверка. Новый порт 5460 проверяется как собственный; старые порты не останавливаются для освобождения. Runtime/child captures получают настоящий exit/creation/path/SHA, полные stdout/stderr и ограничения покрытия, без выдуманного zero или непрерывного контроля.

## Достижимые подзадачи и ворота

| UTC | Подзадача | Условие готовности |
|---|---|---|
| 15:08–15:40 | Пять начальных позиций, точный план, реальные голоса; ресурсный gate | Настоящее большинство фиксированного состава. Частная новая D-установка и prospectively reviewed helpers/inventory. |
| 15:40–17:10 | SQL5 feasibility | Новый empty diagnostic проверяет extended-protocol гипотезу без подмены SQL: real Bind, затем временно не forward исходный Execute; продолжается чтение backend. Точные 5/2/10 и real server57014. При успехе — отдельно reviewed Observe и один полноразмерный fault на новых полных базах. |
| 17:10–19:20 | Lifecycle/audit crosswalk и реальные пробелы | Каждая исходная clause → producer/route → named raw assertion/oracle → независимый verdict. Существующие C2 cases используются лишь при доказанной эквивалентности. Missing finite RBAC/reference/CAS/current-rights/delete-versus-write случаи проверяются в новых fixtures. |
| 19:20–20:30 | Интеграция и целевой freeze | Exact candidate/source/package. Все затронутые осмысленные регрессии, полная stock backup/newrestore/downgrade цепочка и честный PS7/PS5 контракт. |
| 20:30–21:38 | Независимая проверка | QA/TD полный finite acceptance, Customer readonly actual trust states/nonempty preview, точная матрица критериев и новое предложение. |
| 21:38–23:08 | Резерв 90 минут и поставка | Только после принятия: exact-head CI, public source/ZIP/tag/receipt, независимая загрузка/manifest, новая пустая пользовательская установка, сохранность прежней 0.6.1. |

SQL5 гипотеза не выдаётся за доказанный механизм. Реальный unchanged production SQL/Bind/Execute, backend PID, server57014, actual native controlled refusal и полный source/untouched verification PRE/POST обязательны. Нельзя увеличивать тайм-ауты, подменять SELECT на pg_sleep, добавлять production fault flags или сокращать corpus ради приёмки. Наблюдаемый extended-cycle timeout не автоматически означает доказанную CPU-временную границу: характер события явно раскрывается.

При неподтверждённой осуществимости до 17:10 прекращается churn этого инструмента. Оставшееся время идёт на независимые lifecycle/audit проверки. Audit/delete-only поставка с физически исключённым unsafe Apply возможна только отдельным новым конкретным предложением, реальным голосованием, новым exact binary/package и затронутой приёмкой. Автоматической уступки критериям нет. Сохранённый OPEN не является основанием прекращать всю независимую работу раньше бюджета.

## Владельцы и FLW

Фиксированные пять голосов: Root, PM /root/pm_s9, Customer /root/customer_s6, QA_ProcessLogAuditor /root/qa_process, TechnicalDebt /root/technical_debt. Председатель — стенд, интеграция и поставка; отдельный профильный разработчик может делать draft observer/fixtures. QA не автор проверяемого изменения; QA и TD — разные аудиторы, наблюдают до опасного запуска, имеют STOP с точной областью и доказательством. PM — исходный контракт/crosswalk, Customer — понятность UI и реальные сценарии. Не более четырёх активных агентов одновременно; позиции и голоса можно собирать последовательно.

Минимальный допустимый риск потери пользовательских данных. Readonly/draft feasibility — пропорциональный контроль, destructive integrated candidate — полный FLW. Общие файлы/ресурсы имеют одного назначенного владельца; большие I/O/тайминговые fault-прогоны сериализуются. Не обещается закрытие всех пунктов, если обязательная проверка не пройдена. Старые голоса evidence-only не разрешают новую поставку.
