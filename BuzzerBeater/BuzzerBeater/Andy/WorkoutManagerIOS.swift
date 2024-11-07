
//WorkoutManagerIOS.swift
//  BuzzerBeater
//
//  Created by Giwoo Kim on 10/30/24.
//
import CoreLocation
import HealthKit
import Foundation
import SwiftUI
import WorkoutKit

struct metadataForRouteDataPoint: Equatable, Identifiable, Codable{
    var id: UUID = UUID()
    var timeStamp: Date
    
    var boatHeading : Double?
    
    var windSpeed: Double  // m/s
    var windDirection: Double?  //deg
    var windCorrectionDetent : Double
    
}


class WorkoutManager: ObservableObject
{
    static let shared = WorkoutManager()
    let locationManager = LocationManager.shared
    let windDetector = WindDetector.shared
    let healthService = HealthService.shared
    let healthStore = HealthService.shared.healthStore
    
    
    let timeIntervalForRoute = TimeInterval(3)
    let timeIntervalForWind = TimeInterval(60*1)
    
    var workout: HKWorkout?
    var workoutBuilder: HKWorkoutBuilder?
    var workoutSession: HKWorkoutSession?
    var workoutRouteBuilder: HKWorkoutRouteBuilder?
    
    // for later use
    var appIdentifier: String?
    var routeIdentifier: String?
    
    var isWorkoutActive: Bool = false
    var lastHeading: CLHeading?
    
    var timerForLocation: Timer?
    var timerForWind: Timer?
    var metadataForWorkout: [String: Any] = [:] // AppIdentifier, 날짜,
    var metadataForRoute: [String: Any] = [:]   // RouteIdentifer, timeStamp, WindDirection, WindSpeed
    var metadataForRouteDataPointArray : [metadataForRouteDataPoint] = []
    let routeDataQueue = DispatchQueue(label: "com.lavender.buzzbeater.routeDataQueue")
    
    // endTime은 3시간 이내로 제한 즉 한세션의 최대 크기를 제한하도록 함. 나중에 사용예정
    // 기존의  locationManager사용
    
    var startDate: Date? = Date()
    var endDate : Date?  = Date()
    var previousLocation: CLLocation?
    var totalDistance: Double = 0
    
    
    func startWorkout(startDate: Date) {
        // 운동을 시작하기 전에 HKWorkoutBuilder를 초기화
        if isWorkoutActive  { return }
        isWorkoutActive = true
        
        let workoutConfiguration = HKWorkoutConfiguration()
        workoutConfiguration.activityType = .sailing
        workoutConfiguration.locationType = .outdoor
        
        workoutBuilder =  HKWorkoutBuilder(healthStore: healthStore, configuration: workoutConfiguration, device: .local())
        
        guard let workoutBuilder = workoutBuilder else {
            print("workoutBuilder is nil ")
            return
        }
        self.workoutRouteBuilder = HKWorkoutRouteBuilder(healthStore: self.healthStore, device: .local())
        
        workoutBuilder.beginCollection(withStart: startDate, completion: { (success, error) in
            if success {
                print("Started collecting workout data from workoutBuilder \(String(describing: self.workoutBuilder))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.startTimer()
                }
                
            } else {
                print("Error starting workout collection: \(error?.localizedDescription ?? "Unknown error")")
            }
        })
        
        
    }
    
    func collectData(startDate: Date, endDate: Date,  metadataForWorkout: [String: Any]?) {
        // 데이터 수집 예시
        
        guard let workoutBuilder = workoutBuilder else {
            print("workoutBuilder is nil")
            return
        }
        
        if let metadataForWorkout = metadataForWorkout {
            print("metadata in the collectData\(metadataForWorkout)")
            
            workoutBuilder.addMetadata(metadataForWorkout) { (success, error) in
                guard success else {
                    print("==========Error adding metadata:\(error?.localizedDescription ?? "Unknown error")")
                    return
                }
                //    self.finishWorkout(endDate: endDate, metadataForWorkout: metadataForWorkout)
                Task {
                    await self.finishWorkoutAsync(endDate: endDate, metadataForWorkout: self.metadataForWorkout)
                }
            }
        }
        else{
            print("metadataForWorkout is nil or invalid")
            //  self.finishWorkout(endDate: endDate, metadataForWorkout: metadataForWorkout)
            Task {
                await self.finishWorkoutAsync(endDate: endDate, metadataForWorkout: self.metadataForWorkout)
            }
        }
    }
    
    
    
    func finishWorkout(endDate: Date, metadataForWorkout: [String: Any]?) {
        
        if !isWorkoutActive {
            print("Workout is not active \(isWorkoutActive)")
            return
        }
        isWorkoutActive = false
        timerForLocation?.invalidate() // 타이머 중지
        timerForWind?.invalidate()
        
        
        // workoutBuilder 대신에  liveWorkoutBuilder를 사용함
        // Apple  공식문서에  session.end()를 build.endCollection보다 먼저 실행함
        //https://developer.apple.com/documentation/healthkit/workouts_and_activity_rings/running_workout_sessions
        //     workoutSession.end() 는 IOS버전에는 있으면 안됨
  
        guard let workoutBuilder = self.workoutBuilder else {
            print("workoutBuilder is nil ")
            return
        }
        workoutBuilder.endCollection(withEnd: endDate) { [weak self] success, error in
            guard let self = self else { return } // Ensure `self` is valid
            
            guard success else {
                print("endCollection:\(error?.localizedDescription ?? "Unknown error")")
                return
            }
            print("Workout endCollectio end at \(endDate)")
            
            // Finish the workout and save it to HealthKit
            
            workoutBuilder.finishWorkout { workout, error in
                guard  let workout = workout else {
                    print("finishWorkout:\(error?.localizedDescription ?? "Unknown error")")
                    return
                    
                }
                self.printWorkoutActivityType(workout: workout)
                
                self.metadataForRoute = self.makeMetadataForRoute(routeIdentifier: "seastheDayroute", metadataForRouteDataPointArray: self.metadataForRouteDataPointArray)
                print("metadataForRoute \(self.metadataForRoute)")
                
                Task{
                    let result =   await self.finishRoute(workout: workout, metadataForRoute: self.metadataForRoute)
                    switch result {
                    case .success(let route):
                        print("Successfully finished route: \(route) ")
                    case .failure(let error):
                        print("Failed to finish route with error: \(error.localizedDescription)")
                        
                    }
                }
            }
        }
    }
    
    // async 버전으로 만들고  await 을사용해서 모든 비동기호출을 마치고 종료할수있도록 함
    // try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>)
    // let workout = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKWorkout, Error>)
    
    func finishWorkoutAsync(endDate: Date, metadataForWorkout: [String: Any]?) async {
        if !isWorkoutActive {
            print("Workout is not active \(isWorkoutActive)")
            return
        }
        isWorkoutActive = false
        timerForLocation?.invalidate() // 타이머 중지
        timerForWind?.invalidate()
        
        guard let workoutBuilder = self.workoutBuilder else {
            print("WorkoutBuilder is nil")
            return
        }
        // workoutSession이 먼저 종료되어야 한다고 공식문서에 되어있으나 IOS에서 사용하지 않으
        // HKQauantitySample에 추가해봤으나 작동 안함.
      //  self.updateWorkoutDistance(self.totalDistance )
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                workoutBuilder.endCollection(withEnd: endDate) { success, error in
                    if let error = error {
                        print("endCollection Error: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else {
                        print("Workout endCollection at \(endDate)")
                        continuation.resume()
                    }
                }
            }
            
            let workout = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKWorkout, Error>) in
                workoutBuilder.finishWorkout { workout, error in
                    if let error = error {
                        print("finishWorkout Error: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else if let workout = workout {
                        print("Preparing to finish route with workout: \(workout) and metadata: \(String(describing: self.metadataForRoute))")
                        
                        // Resume continuation after workout is finalized
                        if let totalDistance = workout.metadata?["TotalDistance"] as? Double {
                            let totalDistanceInt = Int(totalDistance)
                            print("Workout finished with total distance: \(totalDistanceInt) meters")
                        } else {
                            print("No distance data available.")
                        }
                        continuation.resume(returning: workout)
                    } else {
                        continuation.resume(throwing:  HealthKitError.unknownError)
                    }
                }
            }
            
            // Handle route completion separately after finishing the workout
            
            Task {
                self.printWorkoutActivityType(workout: workout)
                self.metadataForRoute = self.makeMetadataForRoute(
                    routeIdentifier: "seastheDayroute",
                    metadataForRouteDataPointArray: self.metadataForRouteDataPointArray
                )
                let routeResult = await self.finishRoute(workout: workout, metadataForRoute: self.metadataForRoute)
                switch routeResult {
                case .success(let route):
                    print("Successfully finished route. Workout UUID: \(workout.uuid), Route UUID: \(route.uuid)")
                case .failure(let error):
                    print("Failed to finish route with error: \(error.localizedDescription)")
                }
            }
            
            
        } catch {
            print("An error occurred while finishing the workout: \(error.localizedDescription)")
        }
    }
    // 이 함수 작동안함 에러도 없고 작동도 안하고 ...
    func updateWorkoutDistance(_ distanceInMeters: Double) {
        guard let builder = workoutBuilder else { return }
        print("distance in updateWorkoutDistance: \(distanceInMeters) m")
        let distanceQuantity = HKQuantity(unit: .meter(), doubleValue: distanceInMeters)
        let distanceSample = HKQuantitySample(
            type: HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            quantity: distanceQuantity,
            start: self.startDate ?? Date() ,
            end: self.endDate ?? Date()
        )
      
        Task{
            do {
               //   아래코드는 작동 안함.
                  try await builder.addSamples([distanceSample])

            }
            catch
            { print("Error adding distance sample: \(error)")
            }
        }
        
    }
    func printWorkoutActivityType(workout: HKWorkout) {
        let activityType = workout.workoutActivityType
        print("Activity Type: \(activityType.rawValue)")
        if let totalDistance = workout.metadata?["TotalDistance"] as? Double  {
            let totalDistanceInt = Int(totalDistance)
            print("Total Distance: \(totalDistanceInt) m ")
        }
       
        switch activityType {
        case .sailing:
            print("This workout is sailing.")
        case .cycling:
            print("This workout is indoor cycling.")
        case .running:
            print("This workout is running.")
            // 추가적인 운동 유형에 대한 경우도 여기 추가
        default:
            print("Other activity type.")
        }
    }
    
    
    func startTimer() {
        print("startTimer started")
        timerForLocation = Timer.scheduledTimer(withTimeInterval: timeIntervalForRoute, repeats: true) { [weak self] _ in
            print("timerForLocation started ")
            guard let self = self else {
                print("weak self is nil")
                return }
            if let location = self.locationManager.lastLocation  {
                print("location.horizontalAccuracy: \(location.horizontalAccuracy) location.verticalAccuracy: \(location.verticalAccuracy) ")
                if location.horizontalAccuracy < 50 {
                    Task{
                        do {
                            let distance = location.distance(from: self.previousLocation ?? location)
                            print("insterting RouteData \(location) distance: \(distance)")
                            try await self.insertRouteData([location])
                            //  현재의  location값을 과거 location 값으로 정함
                            self.previousLocation = location
                            self.totalDistance += distance
                            
                            print("totalDistance: \(self.totalDistance ) ")
                            
                        } catch {
                            print("insertRouteData error: \(error)")
                        }
                    }
                } else {
                    print("location accuracy is too low")
                }
            } else {
                print("location is nil")
            }
            
        }
        
        timerForWind = Timer.scheduledTimer(withTimeInterval: timeIntervalForRoute ,  repeats: true) { [weak self] _ in
            // locationManager에값이 있지만 직접 다시 불러오는걸로 테스트를 해보기로함.
            // 이건 태스트목적뿐이고 실제는 그럴 필요가 전혀 없음.
            guard let self = self else { return }
            self.locationManager.locationManager.requestLocation()
            if let location = self.locationManager.locationManager.location {
                // wind 정보 추가  WindDetector에서 direction, speed 정보를 가져와서 metadata 에 저장
                Task{
                    await self.windDetector.fetchCurrentWind(for: location)
                    let metadataForRouteDataPoint = metadataForRouteDataPoint(id: UUID(),
                                                                              timeStamp: Date(),
                                                                              boatHeading: self.locationManager.heading?.trueHeading,
                                                                              windSpeed: self.windDetector.speed ?? 0,
                                                                              windDirection: self.windDetector.direction,
                                                                              windCorrectionDetent: self.windDetector.windCorrectionDetent
                    )
                    
                    self.metadataForRouteDataPointArray.append(metadataForRouteDataPoint)
                    print("metadataForRouteDataPointArray appended...")
                }
            }
        }
        
    }
    
    
    func insertRouteData(_ locations: [CLLocation]) {
        let status = healthStore.authorizationStatus(for: .workoutType())
        if status != .sharingAuthorized {
            print("HealthKit authorization is failed. Cannot insert route data.\(status)")
            return
        }
        else {
            print("HealthKit authorization is successful. \(status)")
        }
        workoutRouteBuilder?.insertRouteData(locations) { success, error in
            if success {
                print("Route data inserted successfully.")
                
            } else {
                print("Error inserting route data: \(String(describing: error))")
            }
        }
        
    }
    
    
    func insertRouteData(_ locations: [CLLocation]) async throws {
        let status = healthStore.authorizationStatus(for: .workoutType())
        guard status == .sharingAuthorized else {
            throw HealthKitError.authorizationFailed
        }
        
        // 비동기 작업으로 변환
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            routeDataQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: HealthKitError.selfNilError)
                    return
                }
                
                self.workoutRouteBuilder?.insertRouteData(locations) { success, error in
                    if let error = error {
                        print("Error inserting route data: \(error.localizedDescription)")
                        return  continuation.resume(throwing: HealthKitError.routeInsertionFailed(error.localizedDescription))
                    }
                    guard success else {
                        return  continuation.resume(throwing: HealthKitError.unknownError)
                    }
                    print("Route data inserted successfully.")
                    continuation.resume()
                }
            }
        }
    }
    
    
    
    
    func finishRoute(workout: HKWorkout, metadataForRoute: [String: Any]?) async -> Result<HKWorkoutRoute, Error> {
        return await withCheckedContinuation { continuation in
            workoutRouteBuilder?.finishRoute(with: workout, metadata: metadataForRoute) { route, error in
                
                if let error = error {
                    print("finishRoute: error \(error.localizedDescription)")
                    return continuation.resume(returning: .failure(error))
                }
                
                guard let route = route else {
                    print("finishRoute: Unknown error occurred, route is nil")
                    let unknownError = NSError(domain: "FinishRouteError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Route is nil"])
                    return continuation.resume(returning: .failure(unknownError))
                }
                
                print("finishRoute: workoutRoute saved successfully route \(route)")
                continuation.resume(returning: .success(route))
            }
        }
    }
    
    
    func startToSaveHealthStore() {
        
        let healthService = HealthService.shared
        
        let workoutManager = WorkoutManager.shared
        
        startDate = Date()
        //        sailingDataCollector.startDate = startDate
        
        healthService.startHealthKit()
        if let startDate  = startDate{
            workoutManager.startWorkout(startDate: startDate)
            print("-------------------- started to save HealthStore --------------------")
        }
        
    }
    
    func endToSaveHealthData(){
        let workoutManager = WorkoutManager.shared
        
        endDate = Date()
        metadataForWorkout = makeMetadataForWorkout(appIdentifier: "seastheDay")
        print("metadata in the endToSaveHealthData: \(metadataForWorkout)")
        if let startDate = startDate, let endDate = endDate {
            workoutManager.collectData(startDate: startDate, endDate: endDate, metadataForWorkout: metadataForWorkout)
            print("collectData works successfully  in the endToSaveHealthData")
        }  else {
            print("startDate or endDate is nil")
        }
        
    }
    func countElements(in jsonString: String) -> Int? {
        // Convert JSON string to Data
        guard let data = jsonString.data(using: .utf8) else { return nil }
        
        do {
            // Decode JSON data into an array of numbers
            let numbers = try JSONDecoder().decode([SailingDataPoint].self, from: data)
            // Return the count of elements
            return numbers.count
        } catch {
            print("Failed to decode JSON: \(error)")
            return nil
        }
    }
    
    func makeMetadataForRoute(routeIdentifier: String, metadataForRouteDataPointArray : [metadataForRouteDataPoint]? ) -> [String: Any] {
        var metadataForRoute: [String: Any] = [:]
        metadataForRoute["RouteIdentifier"] = routeIdentifier
        let data = try? JSONEncoder().encode(metadataForRouteDataPointArray)
        let jsonString = String(data: data!, encoding: .utf8) ?? ""
        metadataForRoute["RouteData"] = jsonString
        
        return metadataForRoute
    }
    
    func makeMetadataForWorkout(appIdentifier: String) -> [String: Any] {
        var metadataForWorkout: [String: Any] = [:]
        metadataForWorkout["AppIdentifier"] = appIdentifier
        metadataForWorkout["TotalDistance"] =  self.totalDistance
        return metadataForWorkout
    }
    
    func labelForQuantityType(_ quantityType: HKQuantityType) -> String {
        switch quantityType.identifier {
        case HKQuantityTypeIdentifier.heartRate.rawValue:
            return "Heart Rate"
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
            return "Distance"
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return "Calories"
        default:
            return "Data"
        }
    }
}

/*
 
 1. **`HKWorkout` 생성 및 저장**:
 - 새로운 `HKWorkout` 객체를 생성하고, `healthStore.save(workout)`을 통해 HealthKit에 저장합니다.
 
 2. **`HKWorkoutRouteBuilder`를 사용하여 경로 데이터 삽입**:
 - `insertRouteData(_:)` 메서드를 호출하여 위치 데이터를 경로에 추가합니다.
 
 3. **경로 마무리 및 메타데이터 저장**:
 - `finishRoute(with:metadata:completion:)` 메서드를 호출하여 `HKWorkoutRoute`를 마무리하고 메타데이터를 추가합니다.
 
 4. **운동 마무리 및 메타데이터 저장**:
 - 운동이 완료되면, `healthStore.end(workout, with: metadata)`와 같은 방법으로 `HKWorkout`을 마무리하고 추가적인 메타데이터를 저장합니다.
 
 이러한 과정을 통해 `HKWorkout`과 `HKWorkoutRoute`가 각각의 메타데이터와 함께 연결되고 저장됩니다. 이 방식으로 운동과 경로에 대한 정보를 효과적으로 관리할 수 있습니다.
 
 
 
 
 */
