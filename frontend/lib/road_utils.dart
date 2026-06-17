bool isSupportedRoad(String? highwayType) {
  const excluded = <String>{
    "motorway",
    "motorway_link",
    "trunk",
    "trunk_link",
  };

  if (highwayType == null) return true;

  return !excluded.contains(highwayType);
}
