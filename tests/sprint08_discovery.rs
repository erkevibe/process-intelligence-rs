use process_intelligence_rs::{
    discovery,
    domain::{Case, Event, EventLog},
};
use process_mining::core::{
    PetriNet,
    process_models::case_centric::petri_net::{ArcType, pnml::import_pnml_reader},
};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

fn log(sequences: &[Vec<&str>]) -> EventLog {
    EventLog {
        name: None,
        warnings: vec![],
        cases: sequences
            .iter()
            .enumerate()
            .map(|(i, s)| Case {
                id: i.to_string(),
                name: None,
                events: s
                    .iter()
                    .enumerate()
                    .map(|(ordinal, activity)| Event {
                        ordinal,
                        activity: (*activity).into(),
                        timestamp: None,
                        lifecycle: None,
                    })
                    .collect(),
            })
            .collect(),
    }
}

// PNML import allocates fresh UUIDs. Prove a complete labelled, weighted graph
// and marking bijection rather than comparing identities or counts alone.
fn isomorphic(a: &PetriNet, b: &PetriNet) -> bool {
    struct Graph {
        descriptors: Vec<String>,
        edges: Vec<Vec<Vec<u32>>>,
        initial: Vec<u64>,
        finals: Vec<Vec<u64>>,
    }
    fn graph(net: &PetriNet) -> Graph {
        let mut ids: Vec<_> = net
            .places
            .keys()
            .chain(net.transitions.keys())
            .copied()
            .collect();
        ids.sort();
        assert!(ids.len() <= 128, "isomorphism node limit: inconclusive");
        let marking =
            |m: &process_mining::core::process_models::case_centric::petri_net::Marking| {
                ids.iter()
                    .map(|id| {
                        m.iter()
                            .find(|(p, _)| p.0 == *id)
                            .map(|(_, n)| *n)
                            .unwrap_or(0)
                    })
                    .collect::<Vec<_>>()
            };
        let initial = marking(net.initial_marking.as_ref().expect("initial"));
        let finals: Vec<_> = net
            .final_markings
            .as_ref()
            .expect("finals")
            .iter()
            .map(marking)
            .collect();
        let mut edges = vec![vec![vec![]; ids.len()]; ids.len()];
        for arc in &net.arcs {
            let (from, to) = match arc.from_to {
                ArcType::PlaceTransition(a, b) | ArcType::TransitionPlace(a, b) => (a, b),
            };
            edges[ids.binary_search(&from).unwrap()][ids.binary_search(&to).unwrap()]
                .push(arc.weight);
        }
        for row in &mut edges {
            for weights in row {
                weights.sort();
            }
        }
        let descriptors = ids
            .iter()
            .enumerate()
            .map(|(i, id)| {
                let kind = if net.places.contains_key(id) {
                    "place".to_string()
                } else {
                    format!(
                        "transition:{}",
                        serde_json::to_string(&net.transitions[id].label).unwrap()
                    )
                };
                let mut final_weights: Vec<_> = finals.iter().map(|m| m[i]).collect();
                final_weights.sort();
                let mut incoming: Vec<_> = edges
                    .iter()
                    .flat_map(|row| row[i].iter().copied())
                    .collect();
                incoming.sort();
                let mut outgoing: Vec<_> = edges[i].iter().flatten().copied().collect();
                outgoing.sort();
                format!(
                    "{kind}|{}|{final_weights:?}|{incoming:?}|{outgoing:?}",
                    initial[i]
                )
            })
            .collect();
        Graph {
            descriptors,
            edges,
            initial,
            finals,
        }
    }
    fn search(
        a: &Graph,
        b: &Graph,
        map: &mut [Option<usize>],
        used: &mut [bool],
        budget: &mut usize,
    ) -> bool {
        *budget += 1;
        assert!(
            *budget <= 100_000,
            "isomorphism search exhausted: inconclusive"
        );
        let next = (0..map.len())
            .filter(|i| map[*i].is_none())
            .min_by_key(|i| {
                b.descriptors
                    .iter()
                    .enumerate()
                    .filter(|(j, d)| !used[*j] && **d == a.descriptors[*i])
                    .count()
            });
        let Some(i) = next else {
            if (0..map.len()).any(|i| a.initial[i] != b.initial[map[i].unwrap()]) {
                return false;
            }
            let mut af = a.finals.clone();
            af.sort();
            let mut bf: Vec<_> = b
                .finals
                .iter()
                .map(|m| {
                    (0..map.len())
                        .map(|i| m[map[i].unwrap()])
                        .collect::<Vec<_>>()
                })
                .collect();
            bf.sort();
            return af == bf;
        };
        for j in 0..map.len() {
            if used[j] || a.descriptors[i] != b.descriptors[j] || a.edges[i][i] != b.edges[j][j] {
                continue;
            }
            if (0..map.len()).any(|k| {
                map[k].is_some_and(|l| {
                    a.edges[i][k] != b.edges[j][l] || a.edges[k][i] != b.edges[l][j]
                })
            }) {
                continue;
            }
            map[i] = Some(j);
            used[j] = true;
            if search(a, b, map, used, budget) {
                return true;
            }
            used[j] = false;
            map[i] = None;
        }
        false
    }
    let a = graph(a);
    let b = graph(b);
    if a.descriptors.len() != b.descriptors.len() || a.finals.len() != b.finals.len() {
        return false;
    }
    let n = a.descriptors.len();
    search(&a, &b, &mut vec![None; n], &mut vec![false; n], &mut 0)
}

// A bounded test-only weighted token evaluator, not a quality metric.
fn accepts(net: &PetriNet, sequence: &[String]) -> bool {
    let mut places: Vec<_> = net.places.keys().copied().collect();
    places.sort();
    let marking = |m: &process_mining::core::process_models::case_centric::petri_net::Marking| {
        places
            .iter()
            .map(|p| {
                m.iter()
                    .find(|(id, _)| id.0 == *p)
                    .map(|(_, n)| *n)
                    .unwrap_or(0)
            })
            .collect::<Vec<_>>()
    };
    let initial = marking(net.initial_marking.as_ref().expect("initial marking"));
    let finals: Vec<_> = net
        .final_markings
        .as_ref()
        .expect("final markings")
        .iter()
        .map(marking)
        .collect();
    let mut queue = VecDeque::from([(initial, 0usize, 0usize)]);
    let mut visited = BTreeSet::new();
    while let Some((tokens, position, steps)) = queue.pop_front() {
        assert!(
            visited.len() <= 4096 && steps <= 100,
            "bounded test evaluator exceeded scope"
        );
        if !visited.insert((tokens.clone(), position)) {
            continue;
        }
        if position == sequence.len() && finals.contains(&tokens) {
            return true;
        }
        for (id, transition) in &net.transitions {
            let next_position = match &transition.label {
                None => position,
                Some(label) if sequence.get(position) == Some(label) => position + 1,
                Some(_) => continue,
            };
            let mut incoming = BTreeMap::<usize, u64>::new();
            let mut outgoing = BTreeMap::<usize, u64>::new();
            for arc in &net.arcs {
                match arc.from_to {
                    ArcType::PlaceTransition(p, t) if t == *id => {
                        *incoming
                            .entry(places.binary_search(&p).expect("known place"))
                            .or_default() += u64::from(arc.weight)
                    }
                    ArcType::TransitionPlace(t, p) if t == *id => {
                        *outgoing
                            .entry(places.binary_search(&p).expect("known place"))
                            .or_default() += u64::from(arc.weight)
                    }
                    _ => (),
                }
            }
            if incoming.iter().any(|(p, n)| tokens[*p] < *n) {
                continue;
            }
            let mut next = tokens.clone();
            for (p, n) in incoming {
                next[p] -= n;
            }
            for (p, n) in outgoing {
                next[p] += n;
            }
            assert!(next.iter().all(|n| *n <= 100), "unbounded token output");
            queue.push_back((next, next_position, steps + 1));
        }
    }
    false
}

#[test]
fn actual_alpha_manual_behavior_and_pnml() {
    let corpus: serde_json::Value =
        serde_json::from_str(include_str!("../fixtures/discovery-alpha/corpus.json")).unwrap();
    for fixture in corpus["fixtures"].as_array().unwrap() {
        let mut sequences = vec![];
        for variant in fixture["variants"].as_array().unwrap() {
            let sequence: Vec<_> = variant["sequence"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap())
                .collect();
            for _ in 0..variant["count"].as_u64().unwrap() {
                sequences.push(sequence.clone());
            }
        }
        let input = log(&sequences);
        let original = input.clone();
        let result = discovery::discover(&input, &|| false).unwrap();
        assert_eq!(input, original);
        assert_eq!(result.cases as u64, fixture["cases"].as_u64().unwrap());
        assert_eq!(result.events as u64, fixture["events"].as_u64().unwrap());
        assert_eq!(
            serde_json::to_value(&result.activities).unwrap(),
            fixture["activities"]
        );
        let mut reader = std::io::Cursor::new(result.pnml.as_bytes());
        let round = import_pnml_reader(&mut reader).unwrap();
        assert_eq!(result.net.places.len(), round.places.len());
        assert_eq!(result.net.transitions.len(), round.transitions.len());
        assert_eq!(result.net.arcs.len(), round.arcs.len());
        assert!(
            isomorphic(&result.net, &round),
            "PNML preserves full labelled weighted graph and markings modulo IDs"
        );
        for expected in fixture["accepted"].as_array().unwrap() {
            let sequence: Vec<_> = expected
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap().to_string())
                .collect();
            assert!(
                accepts(&result.net, &sequence),
                "{} must accept {:?}",
                fixture["id"],
                sequence
            );
            assert!(accepts(&round, &sequence));
        }
        for expected in fixture["rejected"].as_array().unwrap() {
            let sequence: Vec<_> = expected
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s.as_str().unwrap().to_string())
                .collect();
            assert!(
                !accepts(&result.net, &sequence),
                "{} must reject {:?}",
                fixture["id"],
                sequence
            );
            assert!(!accepts(&round, &sequence));
        }
    }
}

#[test]
fn limits_reserved_empty_and_cancel_before_upstream() {
    assert!(discovery::discover(&log(&[]), &|| false).is_err());
    assert!(discovery::discover(&log(&[vec![]]), &|| false).is_err());
    for reserved in ["__START", "__END", "__SILENT__x", " ", "A\0B", "A\u{ffff}B"] {
        assert!(discovery::discover(&log(&[vec![reserved]]), &|| false).is_err());
    }
    assert!(
        discovery::discover(&log(&[vec!["A", "B", "C", "D", "E", "F", "G"]]), &|| false).is_err()
    );
    assert!(discovery::discover(&log(&[vec!["A"; 501]]), &|| false).is_err());
    assert!(discovery::discover(&log(&vec![vec!["A"]; 65]), &|| false).is_err());
    let variants: Vec<_> = (0..33)
        .map(|n| {
            (0..6)
                .map(|bit| if n & (1 << bit) == 0 { "A" } else { "B" })
                .collect()
        })
        .collect();
    assert!(discovery::discover(&log(&variants), &|| false).is_err());
    assert!(discovery::discover(&log(&[vec!["A"]]), &|| true).is_err());
}
