//! Globally bounded clean reusable resources. Authorization is checked by the
//! caller on every operation. Active response/operation ownership is separate.
use crate::{
    domain::ImportError,
    platform::StoredModel,
    repository_v2::{self, Versions},
    storage::Database,
    web::StoredLog,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    mem::size_of,
    sync::{Arc, Mutex, Weak},
};

pub(crate) const BYTE_LIMIT: usize = 134_217_728;
pub(crate) const ENTRY_LIMIT: usize = 8;
const FLIGHT_LIMIT: usize = 64;
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    project: String,
    kind: String,
    id: String,
}
#[derive(Clone)]
enum Resource {
    Log(Arc<StoredLog>),
    Model(Arc<StoredModel>),
}
enum WeakResource {
    Log {
        template: Box<StoredLog>,
        data: Weak<crate::domain::EventLog>,
        source: Weak<crate::domain::EventLog>,
        analysis: Weak<crate::domain::Analysis>,
        provenance: Option<Weak<crate::import_provenance::ImportProvenance>>,
    },
    Model(Weak<StoredModel>),
}
impl WeakResource {
    fn from_resource(resource: &Resource) -> Self {
        match resource {
            Resource::Model(model) => Self::Model(Arc::downgrade(model)),
            Resource::Log(log) => {
                let mut template = Box::new(log.as_ref().clone());
                let empty = Arc::new(crate::domain::EventLog {
                    name: None,
                    cases: vec![],
                    warnings: vec![],
                });
                template.data = empty.clone();
                template.source = empty;
                template.analysis = Arc::new(crate::mining::analyze(&template.data));
                template.provenance = None;
                Self::Log {
                    template,
                    data: Arc::downgrade(&log.data),
                    source: Arc::downgrade(&log.source),
                    analysis: Arc::downgrade(&log.analysis),
                    provenance: log.provenance.as_ref().map(Arc::downgrade),
                }
            }
        }
    }
    fn upgrade(&self) -> Option<Resource> {
        match self {
            Self::Model(model) => model.upgrade().map(Resource::Model),
            Self::Log {
                template,
                data,
                source,
                analysis,
                provenance,
            } => {
                let mut log = template.clone();
                log.data = data.upgrade()?;
                log.source = source.upgrade()?;
                log.analysis = analysis.upgrade()?;
                log.provenance = match provenance {
                    Some(p) => Some(p.upgrade()?),
                    None => None,
                };
                Some(Resource::Log(Arc::new(*log)))
            }
        }
    }
}
#[derive(Default)]
struct Flight {
    versions: Versions,
    result: Option<WeakResource>,
}
struct Entry {
    versions: Versions,
    resource: Resource,
    charge: usize,
    used: u64,
}
#[derive(Default, Clone, Serialize)]
pub(crate) struct CacheStats {
    pub(crate) charged_bytes: usize,
    pub(crate) entries: usize,
    pub(crate) hits: u64,
    pub(crate) misses: u64,
    pub(crate) loads: u64,
    pub(crate) evictions: u64,
    pub(crate) oversize_bypasses: u64,
    pub(crate) flight_hits: u64,
}
#[derive(Default)]
struct State {
    entries: BTreeMap<Key, Entry>,
    stats: CacheStats,
    clock: u64,
    epoch: u64,
}
#[derive(Default)]
pub(crate) struct ResourceCache {
    state: Mutex<State>,
    flights: Mutex<BTreeMap<Key, Weak<Mutex<Flight>>>>,
}
fn busy() -> ImportError {
    ImportError::new("cache_busy", "Ресурс сейчас занят. Повторите запрос позже.")
}
fn conflict() -> ImportError {
    ImportError::new(
        "storage_conflict",
        "Ресурс изменился во время чтения. Повторите запрос.",
    )
}
impl ResourceCache {
    pub(crate) fn new() -> Self {
        Self::default()
    }
    pub(crate) fn stats(&self) -> CacheStats {
        let state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        let mut stats = state.stats.clone();
        stats.entries = state.entries.len();
        stats
    }
    fn flight(&self, key: &Key) -> Result<Arc<Mutex<Flight>>, ImportError> {
        let mut flights = self.flights.lock().map_err(|_| busy())?;
        flights.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = flights.get(key).and_then(Weak::upgrade) {
            return Ok(lock);
        }
        if flights.len() >= FLIGHT_LIMIT {
            return Err(busy());
        }
        let lock = Arc::new(Mutex::new(Flight::default()));
        flights.insert(key.clone(), Arc::downgrade(&lock));
        Ok(lock)
    }
    fn hit(&self, key: &Key, versions: &Versions) -> Result<Option<Resource>, ImportError> {
        // Declared first, so removed payload ownership drops after the guard.
        let mut retired = Vec::new();
        let mut state = self.state.lock().map_err(|_| busy())?;
        if state
            .entries
            .get(key)
            .is_some_and(|e| e.versions != *versions)
        {
            let old = state.entries.remove(key).expect("entry present");
            state.stats.charged_bytes = state.stats.charged_bytes.saturating_sub(old.charge);
            retired.push(old);
        }
        state.clock = state.clock.wrapping_add(1);
        let clock = state.clock;
        if let Some(entry) = state.entries.get_mut(key) {
            entry.used = clock;
            let resource = entry.resource.clone();
            state.stats.hits = state.stats.hits.saturating_add(1);
            return Ok(Some(resource));
        }
        Ok(None)
    }
    fn retain(
        &self,
        key: Key,
        versions: Versions,
        resource: Resource,
        epoch: u64,
    ) -> Result<(), ImportError> {
        let charge = resource_charge(&resource).saturating_add(key_charge(&key, &versions));
        let mut retired = Vec::new();
        let mut state = self.state.lock().map_err(|_| busy())?;
        if charge > BYTE_LIMIT {
            state.stats.oversize_bypasses = state.stats.oversize_bypasses.saturating_add(1);
            return Ok(());
        }
        // A committed invalidation during this load suppresses publication.
        if state.epoch != epoch {
            return Ok(());
        }
        if let Some(old) = state.entries.remove(&key) {
            state.stats.charged_bytes = state.stats.charged_bytes.saturating_sub(old.charge);
            retired.push(old);
        }
        while state.entries.len() >= ENTRY_LIMIT
            || state.stats.charged_bytes.saturating_add(charge) > BYTE_LIMIT
        {
            let victim = state
                .entries
                .iter()
                .min_by_key(|(_, e)| e.used)
                .map(|(k, _)| k.clone());
            let Some(victim) = victim else {
                break;
            };
            let old = state.entries.remove(&victim).expect("victim present");
            state.stats.charged_bytes = state.stats.charged_bytes.saturating_sub(old.charge);
            state.stats.evictions = state.stats.evictions.saturating_add(1);
            retired.push(old);
        }
        state.clock = state.clock.wrapping_add(1);
        let used = state.clock;
        state.stats.charged_bytes = state.stats.charged_bytes.saturating_add(charge);
        state.entries.insert(
            key,
            Entry {
                versions,
                resource,
                charge,
                used,
            },
        );
        debug_assert!(
            state.stats.charged_bytes <= BYTE_LIMIT && state.entries.len() <= ENTRY_LIMIT
        );
        Ok(())
    }
    fn get(&self, database: &Database, key: Key, kinds: &[&str]) -> Result<Resource, ImportError> {
        let versions = database.resource_versions(&key.project, &key.id, kinds)?;
        if let Some(resource) = self.hit(&key, &versions)? {
            return Ok(resource);
        }
        {
            let mut state = self.state.lock().map_err(|_| busy())?;
            state.stats.misses = state.stats.misses.saturating_add(1);
        }
        let flight = self.flight(&key)?;
        let mut guard = flight.lock().map_err(|_| busy())?;
        // The preceding load may have completed while this caller waited.
        let versions = database.resource_versions(&key.project, &key.id, kinds)?;
        if let Some(resource) = self.hit(&key, &versions)? {
            return Ok(resource);
        }
        if guard.versions == versions
            && let Some(resource) = guard.result.as_ref().and_then(WeakResource::upgrade)
        {
            let mut state = self.state.lock().map_err(|_| busy())?;
            state.stats.flight_hits = state.stats.flight_hits.saturating_add(1);
            return Ok(resource);
        }
        let epoch = {
            let mut state = self.state.lock().map_err(|_| busy())?;
            state.stats.loads = state.stats.loads.saturating_add(1);
            state.epoch
        };
        let (resource, loaded_versions) = if key.kind == "log" {
            let (log, versions) = repository_v2::load_log(database, &key.project, &key.id)?;
            (Resource::Log(Arc::new(log)), versions)
        } else {
            let (model, versions) = repository_v2::load_model(database, &key.project, &key.id)?;
            (Resource::Model(model), versions)
        };
        if database.resource_versions(&key.project, &key.id, kinds)? != loaded_versions {
            return Err(conflict());
        }
        tracing::info!(project_id=%key.project,resource_kind=%key.kind,resource_id=%key.id,record_versions=?loaded_versions,"resource_cache_loaded");
        guard.versions = loaded_versions.clone();
        guard.result = Some(WeakResource::from_resource(&resource));
        self.retain(key, loaded_versions, resource.clone(), epoch)?;
        Ok(resource)
    }
    pub(crate) fn get_log(
        &self,
        database: &Database,
        project: &str,
        id: &str,
    ) -> Result<StoredLog, ImportError> {
        let resource = self.get(
            database,
            Key {
                project: project.into(),
                kind: "log".into(),
                id: id.into(),
            },
            repository_v2::LOG_KINDS,
        )?;
        match resource {
            Resource::Log(log) => Ok(log.as_ref().clone()),
            _ => unreachable!(),
        }
    }
    pub(crate) fn get_model(
        &self,
        database: &Database,
        project: &str,
        id: &str,
    ) -> Result<Arc<StoredModel>, ImportError> {
        let resource = self.get(
            database,
            Key {
                project: project.into(),
                kind: "model".into(),
                id: id.into(),
            },
            repository_v2::MODEL_KINDS,
        )?;
        match resource {
            Resource::Model(model) => Ok(model),
            _ => unreachable!(),
        }
    }
    pub(crate) fn invalidate(&self, project: &str, log_ids: &[String], model_ids: &[String]) {
        let mut retired = Vec::new();
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        state.epoch = state.epoch.wrapping_add(1);
        for (kind, ids) in [("log", log_ids), ("model", model_ids)] {
            for id in ids {
                let key = Key {
                    project: project.into(),
                    kind: kind.into(),
                    id: id.clone(),
                };
                if let Some(old) = state.entries.remove(&key) {
                    state.stats.charged_bytes =
                        state.stats.charged_bytes.saturating_sub(old.charge);
                    retired.push(old);
                }
            }
        }
    }
}
// Each owned heap allocation receives 32 additional bytes for alignment and
// allocator overhead. Shared data/source are deliberately charged separately.
fn string_charge(value: &String) -> usize {
    value
        .capacity()
        .saturating_add(if value.capacity() > 0 { 32 } else { 0 })
}
fn vec_charge<T>(values: &Vec<T>) -> usize {
    values
        .capacity()
        .saturating_mul(size_of::<T>())
        .saturating_add(if values.capacity() > 0 { 32 } else { 0 })
}
fn opt_string(value: &Option<String>) -> usize {
    value.as_ref().map_or(0, string_charge)
}
fn strings(values: &Vec<String>) -> usize {
    vec_charge(values).saturating_add(values.iter().map(string_charge).sum::<usize>())
}
fn log_charge(log: &crate::domain::EventLog) -> usize {
    let mut bytes = size_of::<crate::domain::EventLog>()
        .saturating_add(32)
        .saturating_add(opt_string(&log.name))
        .saturating_add(strings(&log.warnings))
        .saturating_add(vec_charge(&log.cases));
    for case in &log.cases {
        bytes = bytes
            .saturating_add(string_charge(&case.id))
            .saturating_add(opt_string(&case.name))
            .saturating_add(vec_charge(&case.events));
        for event in &case.events {
            bytes = bytes
                .saturating_add(string_charge(&event.activity))
                .saturating_add(opt_string(&event.lifecycle));
        }
    }
    bytes
}
fn analysis_charge(a: &crate::domain::Analysis) -> usize {
    let mut bytes = size_of::<crate::domain::Analysis>()
        .saturating_add(32)
        .saturating_add(vec_charge(&a.nodes))
        .saturating_add(vec_charge(&a.edges))
        .saturating_add(vec_charge(&a.variants));
    for node in &a.nodes {
        bytes = bytes
            .saturating_add(string_charge(&node.id))
            .saturating_add(string_charge(&node.label));
    }
    for edge in &a.edges {
        bytes = bytes
            .saturating_add(string_charge(&edge.id))
            .saturating_add(string_charge(&edge.source))
            .saturating_add(string_charge(&edge.target));
    }
    for variant in &a.variants {
        bytes = bytes
            .saturating_add(string_charge(&variant.id))
            .saturating_add(strings(&variant.sequence))
            .saturating_add(strings(&variant.case_ids));
    }
    bytes
}
fn model_charge(model: &StoredModel) -> usize {
    let p = &model.model;
    let mut bytes = size_of::<StoredModel>()
        .saturating_add(32)
        .saturating_add(string_charge(&model.id))
        .saturating_add(string_charge(&model.name))
        .saturating_add(opt_string(&model.source_log))
        .saturating_add(string_charge(&p.process_id))
        .saturating_add(string_charge(&p.name))
        .saturating_add(opt_string(&p.discovery))
        .saturating_add(vec_charge(&p.nodes))
        .saturating_add(vec_charge(&p.flows));
    for n in &p.nodes {
        bytes = bytes
            .saturating_add(string_charge(&n.id))
            .saturating_add(string_charge(&n.label));
    }
    for f in &p.flows {
        bytes = bytes
            .saturating_add(string_charge(&f.id))
            .saturating_add(string_charge(&f.source))
            .saturating_add(string_charge(&f.target))
            .saturating_add(vec_charge(&f.waypoints));
    }
    bytes
}
fn resource_charge(resource: &Resource) -> usize {
    match resource {
        Resource::Model(model) => model_charge(model),
        Resource::Log(log) => size_of::<StoredLog>()
            .saturating_add(32)
            .saturating_add(string_charge(&log.id))
            .saturating_add(string_charge(&log.filename))
            .saturating_add(string_charge(&log.source_sha256))
            .saturating_add(opt_string(&log.project_id))
            .saturating_add(opt_string(&log.selected))
            .saturating_add(opt_string(&log.selected_case))
            .saturating_add(log_charge(&log.data))
            .saturating_add(log_charge(&log.source))
            .saturating_add(analysis_charge(&log.analysis))
            .saturating_add(opt_string(&log.filters.case_activity))
            .saturating_add(strings(&log.filters.retain_activities))
            .saturating_add(strings(&log.filters.remove_activities))
            .saturating_add(vec_charge(&log.calendar.weekdays))
            .saturating_add(vec_charge(&log.calendar.holidays))
            .saturating_add(opt_string(&log.calendar.timezone))
            .saturating_add(log.provenance.as_ref().map_or(0, |p| p.charge())),
    }
}
fn key_charge(key: &Key, versions: &Versions) -> usize {
    // Fixed excess also covers BTree node slots and cache/key/entry metadata.
    1024usize
        .saturating_add(size_of::<Entry>())
        .saturating_add(size_of::<Key>())
        .saturating_add(string_charge(&key.project))
        .saturating_add(string_charge(&key.kind))
        .saturating_add(string_charge(&key.id))
        .saturating_add(vec_charge(versions))
        .saturating_add(
            versions
                .iter()
                .map(|(kind, _)| string_charge(kind))
                .sum::<usize>(),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn model(id: &str) -> Resource {
        Resource::Model(Arc::new(StoredModel {
            id: id.into(),
            name: "m".into(),
            revision: 1,
            source_log: None,
            model: crate::bpmn::ProcessModel {
                schema_version: 1,
                process_id: "p".into(),
                name: "m".into(),
                nodes: vec![],
                flows: vec![],
                discovery: None,
            },
        }))
    }
    #[test]
    fn entry_limit_evicts_without_aliasing_projects_or_versions() {
        let cache = ResourceCache::new();
        for n in 0..10 {
            cache
                .retain(
                    Key {
                        project: format!("p{n}"),
                        kind: "model".into(),
                        id: "same".into(),
                    },
                    vec![("model".into(), 1)],
                    model("same"),
                    0,
                )
                .unwrap();
        }
        let stats = cache.stats();
        assert_eq!(stats.entries, 8);
        assert_eq!(stats.evictions, 2);
        assert!(stats.charged_bytes <= BYTE_LIMIT);
        let key = Key {
            project: "p9".into(),
            kind: "model".into(),
            id: "same".into(),
        };
        assert!(
            cache
                .hit(&key, &vec![("model".into(), 2)])
                .unwrap()
                .is_none()
        );
        assert_eq!(cache.stats().entries, 7);
        cache.invalidate("p8", &[], &["same".into()]);
        assert_eq!(cache.stats().entries, 6);
    }
    #[test]
    fn invalidation_prevents_late_publication_and_flight_registry_prunes() {
        let cache = ResourceCache::new();
        let key = Key {
            project: "p".into(),
            kind: "model".into(),
            id: "m".into(),
        };
        let a = cache.flight(&key).unwrap();
        let b = cache.flight(&key).unwrap();
        assert!(Arc::ptr_eq(&a, &b));
        drop(a);
        drop(b);
        cache.invalidate("p", &[], &["m".into()]);
        cache
            .retain(key, vec![("model".into(), 1)], model("m"), 0)
            .unwrap();
        assert_eq!(cache.stats().entries, 0);
        for n in 0..100 {
            let lock = cache
                .flight(&Key {
                    project: format!("p{n}"),
                    kind: "model".into(),
                    id: "m".into(),
                })
                .unwrap();
            drop(lock);
        }
        assert!(cache.flights.lock().unwrap().len() <= 1);
    }
    #[test]
    fn flight_results_are_weak_and_capacity_charge_counts_reserved_strings() {
        let resource = model("m");
        let weak = WeakResource::from_resource(&resource);
        assert!(weak.upgrade().is_some());
        drop(resource);
        assert!(weak.upgrade().is_none());
        let mut resource = model("m");
        if let Resource::Model(model) = &mut resource {
            let model = Arc::make_mut(model);
            model.name = String::with_capacity(4096);
            model.name.push('x');
        }
        assert!(resource_charge(&resource) >= 4096);
    }
    #[test]
    #[ignore = "requires an explicitly owned pi_s5_* database and an existing oversized valid log"]
    fn postgres_oversize_concurrent_singleflight_uses_one_actual_load() {
        use sha2::Digest;
        use std::{
            io::Write,
            time::{Duration, Instant},
        };

        // Test scheduling only: no production delays or fault flags. Validate
        // ownership before connecting; never print the private connection URL.
        let url = std::env::var("S5_QA_DATABASE_URL").expect("S5_QA_DATABASE_URL required");
        let config: postgres::Config = url
            .parse()
            .expect("invalid private test database configuration");
        assert!(
            config
                .get_dbname()
                .is_some_and(|name| name.starts_with("pi_s5_") && name.len() > 6),
            "only an explicitly owned pi_s5_* database is allowed"
        );
        let project = std::env::var("S5_QA_PROJECT_ID").expect("S5_QA_PROJECT_ID required");
        let id = std::env::var("S5_QA_LOG_ID").expect("S5_QA_LOG_ID required");
        assert!(!project.is_empty() && id.starts_with("log-"));
        let database = Database::connect(url).expect("owned test database must be ready schema2");
        let before_revision = database
            .project_header(&project)
            .unwrap()
            .expect("owned project missing")
            .0;
        let before_versions = database
            .resource_versions(&project, &id, repository_v2::LOG_KINDS)
            .unwrap();
        assert_eq!(before_versions.len(), 4, "complete valid log required");
        let cache = Arc::new(ResourceCache::new());
        let key = Key {
            project: project.clone(),
            kind: "log".into(),
            id: id.clone(),
        };
        let flight = cache.flight(&key).unwrap();
        let gate = flight.lock().unwrap();
        let mut threads = Vec::new();
        for _ in 0..2 {
            let cache = cache.clone();
            let database = database.clone();
            let project = project.clone();
            let id = id.clone();
            threads.push(std::thread::spawn(move || {
                cache.get_log(&database, &project, &id)
            }));
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while cache.stats().misses < 2 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let actual_misses = cache.stats().misses;
        drop(gate);
        // JoinHandle owns each returned log, preserving the first active
        // resource's payload while the second waiter upgrades weak identities.
        let first = threads
            .remove(0)
            .join()
            .expect("first cache thread panicked")
            .expect("first load failed");
        let second = threads
            .remove(0)
            .join()
            .expect("second cache thread panicked")
            .expect("second load failed");
        assert_eq!(
            actual_misses, 2,
            "both real SQL version reads must reach the flight gate within five seconds"
        );
        assert!(Arc::ptr_eq(&first.data, &second.data));
        assert!(Arc::ptr_eq(&first.source, &second.source));
        assert!(Arc::ptr_eq(&first.analysis, &second.analysis));
        struct HashWriter(sha2::Sha256);
        impl Write for HashWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.0.update(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        fn full_sha(log: &StoredLog) -> String {
            let mut writer = HashWriter(sha2::Sha256::new());
            serde_json::to_writer(&mut writer, log).expect("full resource serialization failed");
            format!("{:x}", writer.0.finalize())
        }
        let first_sha = full_sha(&first);
        assert_eq!(first_sha, full_sha(&second));
        let stats = cache.stats();
        assert_eq!(stats.loads, 1);
        assert_eq!(stats.flight_hits, 1);
        assert_eq!(stats.oversize_bypasses, 1);
        assert_eq!(stats.entries, 0);
        assert_eq!(stats.charged_bytes, 0);
        assert_eq!(
            database.project_header(&project).unwrap().unwrap().0,
            before_revision
        );
        assert_eq!(
            database
                .resource_versions(&project, &id, repository_v2::LOG_KINDS)
                .unwrap(),
            before_versions
        );
        println!(
            "singleflight_actual_db_read_only project={project} resource={id} full_sha256={first_sha} loads={} flight_hits={} oversize_bypasses={} entries={} charged_bytes={}",
            stats.loads,
            stats.flight_hits,
            stats.oversize_bypasses,
            stats.entries,
            stats.charged_bytes
        );
        drop(first);
        drop(second);
        drop(flight);
        assert!(
            cache
                .flights
                .lock()
                .unwrap()
                .values()
                .all(|flight| flight.strong_count() == 0)
        );
    }
}
