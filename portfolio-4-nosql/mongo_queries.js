// =========================================================================
// ECEWS SPEED Osun Hub - MongoDB queries, indexing and updates
// Run AFTER mongo_setup.js + mongoimport:
//   mongosh --quiet mongo_queries.js > evidence/mongo_output.txt
// =========================================================================
db = db.getSiblingDB("speed_osun");
const col = db.client_records;
const TODAY = ISODate("2026-11-09");
const h = (t) => print("\n==================== " + t + " ====================");
const planSummary = (exp) => {
  const s = exp.executionStats;
  const stages = [];
  (function walk(p) { if (!p) return; stages.push(p.stage + (p.indexName ? "(" + p.indexName + ")" : "")); walk(p.inputStage); (p.inputStages || []).forEach(walk); })(exp.queryPlanner.winningPlan);
  return { plan: stages.join(" <- "), nReturned: s.nReturned, totalDocsExamined: s.totalDocsExamined, totalKeysExamined: s.totalKeysExamined, executionTimeMillis: s.executionTimeMillis };
};

h("0. Collection size");
printjson({ documents: col.countDocuments(), indexes: col.getIndexes().map(i => i.name) });
printjson(col.aggregate([{ $group: { _id: null, avgBytes: { $avg: { $bsonSize: "$$ROOT" } }, maxBytes: { $max: { $bsonSize: "$$ROOT" } }, maxPickups: { $max: { $size: "$pickups" } } } }]).toArray()[0]);

h("1. Open one client's full chart (single read, no joins)");
printjson(col.findOne({ _id: "OS-012345" }, { "pickups": { $slice: -3 }, "tb_screenings": 1, "viral_loads": 1, "art": 1, "demographics": 1 }));
printjson(planSummary(col.find({ _id: "OS-012345" }).explain("executionStats")));

h("2. IIT risk list (active + appointment passed) - BEFORE index");
const iitFilter = { "art.current_status": "Active", "art.next_appointment_date": { $lt: TODAY } };
const iitQuery = () => col.find(iitFilter, { _id: 1, "demographics.lga": 1, "art.next_appointment_date": 1 }).sort({ "art.next_appointment_date": 1 }).limit(5);
printjson(planSummary(iitQuery().explain("executionStats")));

col.createIndex({ "art.current_status": 1, "art.next_appointment_date": 1 }, { name: "idx_status_next_appt" });

h("2b. IIT risk list - AFTER compound index (same ESR design as PostgreSQL)");
printjson(planSummary(iitQuery().explain("executionStats")));
printjson(iitQuery().toArray());

h("3. Viral suppression rate per LGA using each client's LATEST resulted VL (aggregation pipeline)");
printjson(col.aggregate([
  { $match: { "art.current_status": "Active" } },
  { $project: {
      lga: "$demographics.lga",
      latest: { $last: { $filter: { input: "$viral_loads", cond: { $ne: ["$$this.status", "Pending"] } } } } } },
  { $match: { latest: { $ne: null } } },
  { $group: { _id: "$lga",
      tested: { $sum: 1 },
      suppressed: { $sum: { $cond: [{ $eq: ["$latest.status", "Suppressed"] }, 1, 0] } } } },
  { $project: { _id: 0, lga: "$_id", tested: 1, suppressed: 1,
      suppression_rate_pct: { $round: [{ $multiply: [{ $divide: ["$suppressed", "$tested"] }, 100] }, 2] } } },
  { $sort: { suppression_rate_pct: 1 } },
  { $limit: 5 }
]).toArray());

h("4. Multikey index: clients ever confirmed with TB in Osogbo");
col.createIndex({ "demographics.lga": 1, "tb_screenings.status": 1 }, { name: "idx_lga_tb_status" });
const tbQ = { "demographics.lga": "Osogbo", "tb_screenings.status": "Confirmed-TB" };
printjson({ count: col.countDocuments(tbQ) });
printjson(planSummary(col.find(tbQ).explain("executionStats")));

h("5. Record a new MMD pickup - ONE atomic single-document update");
// In PostgreSQL this needed a multi-statement transaction across two tables
// (Portfolio 3, Scenario 1). Here the history and the snapshot live in the
// same document, and MongoDB guarantees atomicity per document.
const before = col.findOne({ _id: "OS-012345" }, { "art.facility": 1, "art.next_appointment_date": 1, n: { $size: "$pickups" } });
const pickupDate = before.art.next_appointment_date;
const nextAppt = new Date(pickupDate.getTime() + 90 * 86400000);
printjson(col.updateOne(
  { _id: "OS-012345", "pickups.date": { $ne: pickupDate } },   // idempotent: no duplicate visit
  { $push: { pickups: { date: pickupDate, facility: before.art.facility, months_dispensed: 3, next_appointment: nextAppt } },
    $set: { "art.last_pickup_date": pickupDate, "art.next_appointment_date": nextAppt } }
));
printjson({ before: before, after: col.findOne({ _id: "OS-012345" }, { "art.next_appointment_date": 1, n: { $size: "$pickups" } }) });

h("6. Schema validation rejects a malformed record");
try {
  col.insertOne({ _id: "OS-BAD-0001", demographics: { gender: "Unknown", birth_year: 1990, lga: "Osogbo" },
                  art: { enrollment_date: TODAY, regimen: "TLD", current_status: "Active", next_appointment_date: TODAY },
                  pickups: [], tb_screenings: [], viral_loads: [] });
} catch (e) {
  print("Rejected as expected:", e.errmsg || e.message);
}
