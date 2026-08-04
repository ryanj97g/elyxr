// The four-word pairing phrase (§08). Both devices show it — the client while
// it waits, the server in the approval prompt — and a person checks they match.
//
// The pair request body is fixed to {device, client} and rejects unknown
// fields, so the phrase can't ride along in the request. Instead both ends
// DERIVE it from that same body with this algorithm, so they always agree
// without transmitting it. lymnal's pairing.rs mirrors this word list and
// selection exactly.

/// The shared word list. Keep in lockstep with lymnal's pairing.rs.
const List<String> kPhraseWords = [
  'copper', 'anchor', 'violet', 'moth', 'cedar', 'harbor', 'ember', 'quartz',
  'willow', 'lantern', 'marble', 'otter', 'saffron', 'thistle', 'cobalt', 'raven',
  'meadow', 'pewter', 'cinder', 'juniper', 'beacon', 'sable', 'opal', 'fern',
];

/// FNV-1a 32-bit hash of the seed, then four distinct words chosen by an LCG
/// walked from that hash. Deterministic and identical across client and server.
String phraseFor(String device, String client) {
  final seed = '$device|$client';
  int h = 0x811c9dc5;
  for (final code in seed.codeUnits) {
    h = (h ^ code) & 0xffffffff;
    h = (h * 0x01000193) & 0xffffffff;
  }

  final chosen = <int>[];
  int state = h == 0 ? 1 : h;
  while (chosen.length < 4) {
    // A plain LCG step (Numerical Recipes constants), masked to 32 bits.
    state = (state * 1664525 + 1013904223) & 0xffffffff;
    final idx = state % kPhraseWords.length;
    if (!chosen.contains(idx)) chosen.add(idx);
  }
  return chosen.map((i) => kPhraseWords[i]).join(' ');
}
