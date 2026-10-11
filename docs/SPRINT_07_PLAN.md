# Sprint07 — предварительный просмотр service-import

Окно: 2026-10-11 02:52:21–06:52:21 UTC, четыре часа. Риск-аппетит средний для изолированного preview, минимальный для работающих установок и данных. Фиксированный Совет: Root, Customer customer_s6, PM pm_s7 (прежний pm_final отсутствует в живом реестре), QA/ProcessAuditor qa_process, TD/SkillManager technical_debt. Приглашения и независимые позиции получены до предложения. Эмоциональный советник отдельный, без шестого голоса.

## Решение S7-P1

Root FOR этого точного плана. Настоящий полный EventLogServiceImpl требует широкого Manager/Spring/DAO окружения. В данном спринте **не заявляется запуск полного класса, service pipeline или Portal**. Принимается узкий reference: механически извлечь точные исходные байты `validateLog` и `isInvalidEvent` из закреплённого upstream, без изменения тел/заглушек/переписывания; обернуть нейтральным классом, собрать и выполнить на настоящих OpenXES типах. Это исполнение извлечённых методов, а не полный service oracle. S7-C01 ограничивается этой явной границей; остальные C02–C07 сохраняются.

Root реализует отдельный публичный Rust API и developer example предварительного просмотра. Обычные HTTP/CLI импорты и parser API не меняют поведения. Preview до фильтрации сохраняет byte/event/case/activity limits, UTF-8/XML/DTD/global/type/duplicate проверки. Только отсутствие имени допускается в отдельном admission-пути для последующего объяснённого удаления; пустое или неверно типизированное имя, некорректная дата, дубликаты и неверный тип lifecycle остаются отказами Rust. Не придумывать имя/время. Исходные индексы cases/events и порядок сохраняются. Удаления/default lifecycle отражаются структурированно; wholly empty projection виден явно. Preview не записывает данные и не запускает mining. Обычные импорты/Windows0.5/пользовательские БД/пакеты остаются прежними.

## Задачи и владельцы

1. PM: закреплённый source blob/SHA, строгая механическая extraction двух методов, build/run observation tools; real OpenXES manifest verification, оригинальные тела и generated envelope раздельно. До 03:32:21 feasibility gate. Если fails — сохранить диагностику и перейти к честному research-only результату, не объявлять Rust parity.
2. Root: заранее заморозить малый корпус с ручными ожиданиями. Сценарии отсутствующих name/time/lifecycle, case-insensitive start/complete, suspend/пустой lifecycle, пустые traces/allremoved, source-order/ties, неправильный тип/duplicate/date refusal. Сравнение исходных индексов, имён, lifecycle, времени и counts; runtime/replay idempotence отдельно.
3. Root: отдельный Rust preview API/example, структурированные изменения и documented divergence. Сохранить старые шесть/десять fixture bytes и строгие negative guards, limits до удаления.
4. QA: prospective private ACL/raw/stdout/stderr/exit/hash inventory, независимое воспроизведение fixed candidate, scope extraction/fullservice distinction, meaningful negative/provenance guards, действующие strict regressions. QA не автор изменений.
5. TD: независимый риск/долг/source boundary audit, повторные причины/STOP и пропорциональность. Черновики без нового полного freeze на каждую правку. Один интегрированный кандидат; при дефекте новый exact candidate.
6. Root: scoped CI, публичный PR и guarded merge после majority/QA/TD; независимая проверка публичного source archive и сохранности прежних установок только чтением. Итоговые roadmap/report/docs-only completion.

## Приёмка

| ID | Проверяемый результат |
|---|---|
| A01 | Точный source Git blob/SHA и побайтовые method slices; реальное исполнение extracted methods/OpenXES, никаких заявлений fullclass/service |
| A02 | Заранее frozen literal inputs/expectations; source ordinal/count/time/lifecycle parity в поддержанном пересечении; все divergences явно |
| A03 | Rust opt-in preview показывает removal/default reasons, source identities/order и fully filtered result; idempotence и отказ invalidtyped/duplicate/date |
| A04 | Старые strict parser/API/HTTP wiring не ослаблены, лимиты применяются до удаления, отмена доступна API; meaningful regressions |
| A05 | Независимый QA и другой TD/auditor, реальные голоса, captured/missing/truncated/not-in-run не смешаны |
| A06 | Проверенный head CI, публичный PR/архив Git blobs и read-only сохранность прежних пяти установок/04–05ZIP |

Freeze не позднее 05:22:21UTC с резервом 90 минут на приёмку/доставку. Production HTTP/UI integration, Windows0.6/release, cleanup/migrations/backup, complete Manager defaults/importFromStream/attributes/classifiers, XXE upstream, calendars/DST/miner/BPMN не входят. DISK01 и native5.1 backup остаются открытыми. Контроль подтверждает выбранный контракт, не enterprise parity и не человеческую окончательную приёмку.
