//
//  DataExporter.swift
//  xdrip
//
//  Created by Eduardo Pietre on 07/05/22.
//  Copyright © 2022 Johan Degraeve. All rights reserved.
//

import Foundation
import CoreData
import OSLog


/// DataExporter is tha class responsible for
/// retrieving data from CoreDataManager, converting it
/// into JSON and exporting it into a .json file.
public class DataExporter {
	
	/// Imutable file name for the export.
	private static let exportFileName: String = "XDripExportedData.json"
	
	/// This date will determine when the exported data will begin.
	private let onlyFromDate: Date
	
	/// This date determines when the exported data will stop. (Now)
	private let endDate: Date
	
	/// NSManagedObjectContext to be used
	private let managedObjectContext: NSManagedObjectContext
	
	/// CoreDataManager instance
	private let coreDataManager: CoreDataManager
	
	/// BgReadings instance
	private let bgReadingsAccessor: BgReadingsAccessor
	
	/// Treatments instance
	private let treatmentsAccessor: TreatmentEntryAccessor
	
	/// Calibrations instance
	private let calibrationsAccessor: CalibrationsAccessor
	
	/// Log instance
	private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.dataExporter)

	
	// MARK: - initializer
	
	init(coreDataManager: CoreDataManager) {
		// initialize properties
		self.coreDataManager = coreDataManager
		self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
		self.treatmentsAccessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)
		self.calibrationsAccessor = CalibrationsAccessor(coreDataManager: coreDataManager)
		
		self.managedObjectContext = self.coreDataManager.privateManagedObjectContext
		
		self.onlyFromDate = Date(timeIntervalSinceNow: -Double(UserDefaults.standard.retentionPeriodInDays*24*3600))
		self.endDate = Date()
	}
	
	
	/// convertToJSON takes a dictionary and returns a JSON
	/// representation of it, if possible, else returns nil.
	/// - parameters:
	///     - dict : the dict to be converted into JSON.
	/// - returns:
	///     - String? : the JSON output as a string. nil if an error happened.
	private func convertToJSON(dict: Any) -> String? {
		do {
			// Set sortedKeys, without sortedKeys the key order is random for each element.
			let jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
			let asString = String(data: jsonData, encoding: .utf8)
			return asString
		} catch let error {
			trace("in convertToJSON, error = %{public}@", log: self.log, category: ConstantsLog.dataExporter, type: .error, error.localizedDescription)
		}
		
		return nil
	}
	
	
	/// readingsAsDicts retrieves all bgReadings and returns them as
	/// an array of dicts, read to be converted into JSON.
	/// Must not be called from a background Thread or CoreData will crash.
	/// - returns:
	///     - [[String: Any]] : an array of dicts, each element is a reading.
	private func readingsAsDicts() -> [[String: Any]] {
		let readings = self.bgReadingsAccessor.getBgReadings(from: self.onlyFromDate, to: self.endDate, on: self.managedObjectContext)
		let readingsAsDicts = readings.map { reading in
			return reading.dictionaryRepresentationForNightScoutUpload
		}
		return readingsAsDicts
	}
	
	
	/// treatmentsAsDicts retrieves all treatments and returns them as
	/// an array of dicts, read to be converted into JSON.
	/// Must not be called from a background Thread or CoreData will crash.
	/// - returns:
	///     - [[String: Any]] : an array of dicts, each element is a treatment.
	private func treatmentsAsDicts() -> [[String: Any]] {
		let treatments = self.treatmentsAccessor.getTreatments(fromDate: self.onlyFromDate, toDate: self.endDate, on: self.managedObjectContext)
		let treatmentsAsDicts = treatments.map { treatment in
			return treatment.dictionaryRepresentationForNightScoutUpload()
		}
		return treatmentsAsDicts
	}
	
	
	/// calibrationsAsDicts retrieves all calibrations and returns them as
	/// an array of dicts, read to be converted into JSON.
	/// Must not be called from a background Thread or CoreData will crash.
	/// - returns:
	///     - [[String: Any]] : an array of dicts, each element is a calibration.
	private func calibrationsAsDicts() -> [[String: Any]] {
		let calibrations = self.calibrationsAccessor.getCalibrations(from: self.onlyFromDate, to: self.endDate, on: self.managedObjectContext)
		let calibrationsAsDicts = calibrations.map { calibration -> [String: Any] in
			/// Use the Cal representation, but add the mbg key with bg value.
			var representation =  calibration.dictionaryRepresentationForCalRecordNightScoutUpload
			representation["mbg"] = calibration.bg
			return representation
		}
		return calibrationsAsDicts
	}
	
	
	/// generateJSON generates the JSON will all data and retuns it in an
	/// asynchronous way, calling the callback.
	/// The callback may be called with nil in case of an internal error.
	/// This method can be called from any thread in a safe way.
	/// - parameters:
	///     - callback: ((_ json: String?) -> Void)): a callback that will
	///     be called with the JSON as argument.
	private func generateJSON(callback: @escaping ((_ json: String?) -> Void)) {
		/// In order for this method to be called from any thread in
		/// a safe way, we must make sure that we only access CoreData
		/// from a safe thread, so use mainManagedObjectContext for that.
		coreDataManager.privateManagedObjectContext.perform {
			let dataDict: [String : Any] = [
				"ExportInformation": [
					"BeginDate:": self.onlyFromDate.ISOStringFromDate(),
					"EndDate:": self.endDate.ISOStringFromDate(),
				],
				"BgReadings": self.readingsAsDicts(),
				"Treatments": self.treatmentsAsDicts(),
				"Calibrations": self.calibrationsAsDicts()
			]
			/// Convert dataDict to JSON and returns it.
			let asJSON = self.convertToJSON(dict: dataDict)
			callback(asJSON)
		}
	}
	

	/// exportAllData generates the JSON will all data, writes it to a file and retuns
	/// the file URL in an asynchronous way, calling the callback.
	/// The callback may be called with nil in case of an internal error.
	/// This method can be called from any thread in a safe way.
	/// - parameters:
	///     - callback: ((_ json: URL?) -> Void)): a callback that will
	///     be called with the JSON file URL as argument.
	public func exportAllData(callback: @escaping ((_ file: URL?) -> Void)) {
		self.generateJSON { json in
			/// Json must not be nil.
			guard let json = json else {
				trace("in exportAllData, json is nil", log: self.log, category: ConstantsLog.dataExporter, type: .error)
				callback(nil)
				return
			}
			
			/// Run the code in a background thread,
			/// since this may take a while and crash older devices
			/// if run at the UI thread.
			DispatchQueue.global(qos: .background).async {
				/// The filePath is calculated using the document directory for the app (first element returned by the array) and appending the exportFileName.
				/// If exportFileName already exists, it will be overridden,
				/// so there is no need to check and delete it.
				let filePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(DataExporter.exportFileName)

				/// Write operation may fail.
				do {
					/// Write the json to the file and, if success,
					/// call the callback with the path for the file just written.
					try json.write(to: filePath, atomically: false, encoding: .utf8)
					callback(filePath)
				} catch let error {
					trace("in exportAllData, error = %{public}@", log: self.log, category: ConstantsLog.dataExporter, type: .error, error.localizedDescription)
					callback(nil)
				}
			}
		}
	}

}