import Foundation
import OrbitCore

// The displays' hooks on track E1's entry program: the ENTRY and MAP pages
// show its landing-point prediction (`LandingPointPredicting`), whether it
// flies the CM itself or through the CSM's SCS.

extension CMEntryProgram: LandingPointPredicting {
    /// Where its predictor last put the CM's descent through the drogues'
    /// 24,000 ft, and when (`CMEntryProgram.prediction`); nil before the
    /// first prediction.
    public var predictedLandingPoint: (latitude: Double, longitude: Double, time: Epoch)? {
        prediction.map { ($0.latitude, $0.longitude, $0.time) }
    }
}

extension ApolloSCS: LandingPointPredicting {
    /// Its successor's prediction (the CM's entry program, once the SM has
    /// gone); nil before.
    public var predictedLandingPoint: (latitude: Double, longitude: Double, time: Epoch)? {
        (successor as? LandingPointPredicting)?.predictedLandingPoint
    }
}
