/// Introspection helpers mirroring Oniguruma's C public API for reading
/// metadata off a compiled [Regex].
///
/// This port also exposes the same data directly as `Regex` fields
/// (`numMem`, `numNamed`, `nameTable`); these functions exist so the public
/// surface matches the C library — and the sibling `oniguruma_native` package —
/// 1:1.
library;

import 'onig_errors.dart';
import 'regex.dart';
import 'region.dart';

/// The Oniguruma version this engine is a 1:1 port of (`onig_version`).
const String onigVersionString = '6.9.10';

/// The Oniguruma version string (`onig_version`).
String onigVersion() => onigVersionString;

/// Number of capture groups in [reg], excluding the whole match
/// (`onig_number_of_captures`).
int onigNumberOfCaptures(Regex reg) => reg.numMem;

/// Number of distinct group *names* in [reg] (`onig_number_of_names`).
int onigNumberOfNames(Regex reg) => reg.nameTable.length;

/// The capture-group numbers bound to [name] in [reg], in definition order
/// (`onig_name_to_group_numbers`). Empty if [name] is not a group name.
List<int> onigNameToGroupNumbers(Regex reg, String name) =>
    reg.nameTable[name] ?? const <int>[];

/// The backref group number for [name] (`onig_name_to_backref_number`).
///
/// For a unique name, that group's number. For a duplicated name, the number of
/// the group that actually participated in [region] (the last one that is set),
/// or the last-defined number if [region] is null / none is set. Returns
/// [OnigErr.undefinedNameReference] if [name] is not defined.
int onigNameToBackrefNumber(Regex reg, String name, [OnigRegion? region]) {
  final nums = reg.nameTable[name];
  if (nums == null || nums.isEmpty) return OnigErr.undefinedNameReference;
  if (nums.length == 1) return nums[0];
  if (region != null) {
    for (var i = nums.length - 1; i >= 0; i--) {
      final g = nums[i];
      if (g < region.numRegs && region.beg[g] != OnigRegion.notFound) return g;
    }
  }
  return nums[nums.length - 1];
}
