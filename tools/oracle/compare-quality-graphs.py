"""Compare complete finite accepting marking graphs, including infinite languages.

This is an epsilon-NFA equivalence check, not bounded trace enumeration. Graph
conservation against actual nets is a separate independently checked prerequisite.
Inputs remain read-only; the output must be a new file.
"""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result


def read(path):
    require(path.stat().st_size <= 8 * 1024 * 1024, 'graph_byte_limit')
    data = path.read_bytes()
    require(len(data) <= 8 * 1024 * 1024, 'graph_grew')
    return data, json.loads(data.decode('utf-8-sig'), object_pairs_hook=unique,
                            parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite')))


def validate(graph):
    require(graph['schema_version'] == 1, 'graph_schema')
    require(re.fullmatch('[a-fA-F0-9]{64}', graph['net_sha256']), 'net_hash')
    places, transitions, states = graph['places'], graph['transitions'], graph['states']
    require(isinstance(places, list) and places and len(set(places)) == len(places)
            and all(isinstance(p, str) and p for p in places), 'place_set')
    require(len(places) + len(transitions) <= 128, 'generated_node_limit')
    labels = {}
    for transition in transitions:
        identity, label = transition['id'], transition['label']
        require(isinstance(identity, str) and identity and identity not in labels,
                'transition_identity')
        require(label is None or isinstance(label, str), 'transition_label')
        labels[identity] = label
    require(not set(places) & set(labels), 'node_identity_overlap')
    require(isinstance(states, list) and 0 < len(states) <= 10000, 'marking_limit')
    seen = set()
    for state in states:
        require(isinstance(state, list) and len(state) == len(places)
                and all(integer(n) and 0 <= n <= 255 for n in state), 'wide_marking_shape')
        key = tuple(state)
        require(key not in seen, 'duplicate_marking')
        seen.add(key)
    initial, finals = graph['initial_state'], graph['final_states']
    require(integer(initial) and 0 <= initial < len(states), 'initial_state')
    require(isinstance(finals, list) and len(set(finals)) == len(finals)
            and all(integer(i) and 0 <= i < len(states) for i in finals), 'final_states')
    require(len(graph['edges']) <= 100000, 'graph_edge_limit')
    edges, seen_edges = [[] for _ in states], set()
    for edge in graph['edges']:
        source, target, transition = edge['from'], edge['to'], edge['transition']
        require(integer(source) and integer(target) and 0 <= source < len(states)
                and 0 <= target < len(states) and transition in labels, 'edge_reference')
        require(edge['label'] == labels[transition], 'edge_label_conservation')
        key = (source, transition, target)
        require(key not in seen_edges, 'duplicate_edge')
        seen_edges.add(key)
        edges[source].append((edge['label'], target))
    reachable, pending = {initial}, deque([initial])
    while pending:
        for _, target in edges[pending.popleft()]:
            if target not in reachable:
                reachable.add(target)
                pending.append(target)
    require(len(reachable) == len(states), 'graph_contains_unreachable_states')
    return initial, frozenset(finals), edges


def closure(seed, edges):
    result, pending = set(seed), list(seed)
    while pending:
        for label, target in edges[pending.pop()]:
            if label is None and target not in result:
                result.add(target)
                pending.append(target)
    return frozenset(result)


def advance(states, label, edges):
    return closure({target for source in states for actual, target in edges[source]
                    if actual == label}, edges)


def compare(left, right, max_pairs=10000):
    require(integer(max_pairs) and 1 <= max_pairs <= 10000, 'subset_pair_limit')
    li, lf, le = validate(left)
    ri, rf, re_ = validate(right)
    initial = (closure({li}, le), closure({ri}, re_))
    parents, pending = {initial: None}, deque([initial])
    while pending:
        pair = pending.popleft()
        ls, rs = pair
        if bool(ls & lf) != bool(rs & rf):
            word, current = [], pair
            while parents[current] is not None:
                current, label = parents[current]
                word.append(label)
            return {'status': 'not_equivalent', 'witness': list(reversed(word)),
                    'left_accepts': bool(ls & lf), 'right_accepts': bool(rs & rf),
                    'visited_subset_pairs': len(parents)}
        alphabet = {label for s in ls for label, _ in le[s] if label is not None}
        alphabet.update(label for s in rs for label, _ in re_[s] if label is not None)
        for label in sorted(alphabet):
            following = (advance(ls, label, le), advance(rs, label, re_))
            if following in parents:
                continue
            if len(parents) >= max_pairs:
                return {'status': 'inconclusive', 'reason': 'equivalence_subset_pair_budget',
                        'visited_subset_pairs': len(parents), 'limit': max_pairs}
            parents[following] = (pair, label)
            pending.append(following)
    return {'status': 'equivalent', 'visited_subset_pairs': len(parents),
            'method': 'complete_tau_closure_subset_pair_bisimulation_of_observable_accepting_automata'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('left', type=Path)
    parser.add_argument('right', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--max-pairs', type=int, default=10000)
    args = parser.parse_args()
    lb, left = read(args.left)
    rb, right = read(args.right)
    result = compare(left, right, args.max_pairs)
    result.update(left_graph_sha256=hashlib.sha256(lb).hexdigest(),
                  right_graph_sha256=hashlib.sha256(rb).hexdigest(),
                  scope='Graph language equivalence only; actual net/graph conservation is a separate gate.')
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'status': result['status']}))


if __name__ == '__main__':
    main()
