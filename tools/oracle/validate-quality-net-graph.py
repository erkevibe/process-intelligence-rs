"""Independent weighted-net/complete-marking-graph conservation, standard library only.

This checks an already finite admitted graph against the exact saved net. It does
not replace admission, alignment, observable-language equivalence or a reference.
"""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def natural(value, positive=False):
    require(type(value) is int and (1 if positive else 0) <= value <= 255,
            'bounded_integer_required')
    return value


def validate(raw_bytes, artifact):
    require(len(raw_bytes) <= 16 * 1024 * 1024, 'net_byte_limit')
    net = json.loads(raw_bytes)
    graph = artifact['graph'] if artifact.get('status') == 'admitted' else artifact
    require(graph['schema_version'] == 1, 'graph_schema')
    require(graph['net_sha256'] == hashlib.sha256(raw_bytes).hexdigest(), 'exact_net_hash')
    places = sorted(net['places'])
    transitions = sorted(net['transitions'])
    require(0 < len(places) + len(transitions) <= 128 and len(net['arcs']) <= 256,
            'net_size_limit')
    require(not set(places) & set(transitions), 'disjoint_node_ids')
    require(graph['places'] == places, 'place_order_conservation')
    labels = {}
    for identity, value in net['places'].items():
        require(value['id'] == identity, 'place_identity')
    for identity, value in net['transitions'].items():
        require(value['id'] == identity, 'transition_identity')
        label = value['label']
        require(label is None or isinstance(label, str) and 0 < len(label.encode()) <= 200,
                'transition_label')
        labels[identity] = label
    require(graph['transitions'] == [{'id': t, 'label': labels[t]} for t in transitions],
            'transition_label_conservation')
    indices = {place: index for index, place in enumerate(places)}
    incoming = {transition: {} for transition in transitions}
    outgoing = {transition: {} for transition in transitions}
    arcs = set()
    for arc in net['arcs']:
        source, target = arc['from_to']['nodes']
        require((source, target) not in arcs, 'duplicate_arc')
        arcs.add((source, target))
        weight = natural(arc['weight'], True)
        if arc['from_to']['type'] == 'PlaceTransition':
            require(source in indices and target in labels, 'input_arc_endpoints')
            incoming[target][indices[source]] = weight
        else:
            require(arc['from_to']['type'] == 'TransitionPlace' and
                    source in labels and target in indices, 'output_arc_endpoints')
            outgoing[source][indices[target]] = weight

    def vector(marking):
        require(isinstance(marking, dict) and set(marking) <= set(places), 'marking_places')
        return tuple(natural(marking.get(place, 0)) for place in places)

    require(net['initial_marking'] is not None and len(net['final_markings']) == 1,
            'single_initial_final')
    initial = vector(net['initial_marking'])
    final = vector(net['final_markings'][0])
    supplied = graph['states']
    require(0 < len(supplied) <= 10000, 'state_limit')
    states = [tuple(natural(n) for n in row) for row in supplied]
    require(all(len(row) == len(places) for row in states) and
            len(set(states)) == len(states), 'unique_fixed_width_markings')
    require(type(graph['initial_state']) is int and graph['initial_state'] == 0 and
            states[0] == initial, 'initial_marking_conservation')
    state_index = {state: index for index, state in enumerate(states)}
    require(final in state_index and graph['final_states'] == [state_index[final]],
            'final_marking_conservation')
    expected_edges = set()
    queue, seen = deque([initial]), {initial}
    while queue:
        marking = queue.popleft()
        for transition in transitions:
            if any(marking[index] < weight for index, weight in incoming[transition].items()):
                continue
            following = list(marking)
            for index, weight in incoming[transition].items():
                following[index] -= weight
            for index, weight in outgoing[transition].items():
                following[index] += weight
            require(all(0 <= value <= 255 for value in following), 'token_bound')
            following = tuple(following)
            require(following in state_index, 'enabled_successor_missing')
            expected_edges.add((state_index[marking], state_index[following], transition,
                                labels[transition]))
            require(len(expected_edges) <= 100000, 'edge_limit')
            if following not in seen:
                seen.add(following)
                queue.append(following)
    require(seen == set(states), 'unreachable_supplied_marking')
    require(len(graph['edges']) <= 100000, 'supplied_edge_limit')
    supplied_edges = set()
    for edge in graph['edges']:
        require(type(edge['from']) is int and type(edge['to']) is int, 'edge_indices')
        row = (edge['from'], edge['to'], edge['transition'], edge['label'])
        require(row not in supplied_edges, 'duplicate_graph_edge')
        supplied_edges.add(row)
    require(supplied_edges == expected_edges, 'complete_weighted_firing_edges_disagree')
    return {'status': 'exact_weighted_net_complete_graph_conservation',
            'net_sha256': hashlib.sha256(raw_bytes).hexdigest(),
            'places': len(places), 'transitions': len(transitions),
            'arcs': len(arcs), 'states': len(states), 'edges': len(expected_edges)}


def read(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
            'artifact_type_or_size')
    data = path.read_bytes()
    require(len(data) <= 16 * 1024 * 1024, 'artifact_grew')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('net', type=Path)
    parser.add_argument('graph', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    net, graph = read(args.net), read(args.graph)
    result = validate(net, json.loads(graph))
    result['graph_sha256'] = hashlib.sha256(graph).hexdigest()
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
