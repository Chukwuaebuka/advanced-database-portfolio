// =========================================================================
// ECEWS SPEED Osun Hub - MongoDB collection setup (run BEFORE mongoimport)
//   mongosh --quiet mongo_setup.js
// Creates the collection with a $jsonSchema validator so the "schema-less"
// store still rejects malformed clinical records.
// =========================================================================
db = db.getSiblingDB("speed_osun");
db.client_records.drop();

const dateOrNull = { bsonType: ["date", "null"] };

db.createCollection("client_records", {
  validationLevel: "strict",
  validationAction: "error",
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["_id", "demographics", "art", "pickups", "tb_screenings", "viral_loads"],
      properties: {
        _id: { bsonType: "string", pattern: "^OS-", description: "PEPFAR UID" },
        demographics: {
          bsonType: "object",
          required: ["gender", "birth_year", "lga"],
          properties: {
            gender: { enum: ["Male", "Female"] },
            birth_year: { bsonType: "int", minimum: 1900 },
            lga: { bsonType: "string" },
            senatorial_district: { enum: ["Osun Central", "Osun East", "Osun West"] }
          }
        },
        art: {
          bsonType: "object",
          required: ["enrollment_date", "regimen", "current_status", "next_appointment_date"],
          properties: {
            enrollment_date: { bsonType: "date" },
            clinical_stage: { bsonType: "int", minimum: 1, maximum: 4 },
            current_status: { enum: ["Active", "Transferred-Out", "Lost-To-Follow-Up", "Deceased"] },
            next_appointment_date: { bsonType: "date" }
          }
        },
        pickups: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["date", "months_dispensed"],
            properties: { date: { bsonType: "date" }, months_dispensed: { enum: [1, 2, 3, 6] } }
          }
        },
        viral_loads: {
          bsonType: "array",
          items: {
            bsonType: "object",
            required: ["sample_date", "status"],
            properties: {
              sample_date: { bsonType: "date" },
              result_date: dateOrNull,
              copies_per_ml: { bsonType: ["int", "null"], minimum: 0 },
              status: { enum: ["Suppressed", "Unsuppressed", "Pending"] }
            }
          }
        }
      }
    }
  }
});

print("Collection created with validator:", db.getCollectionInfos({ name: "client_records" })[0].options.validator ? "yes" : "no");
