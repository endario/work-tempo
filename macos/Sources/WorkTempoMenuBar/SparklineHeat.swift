enum SparklineHeat {
    /// Where the average sits between the floor and the highest day, as a
    /// fraction of the fill's height: the point the gradient turns from cold to
    /// warm.
    static func averageFraction(average: Double, floor: Double, peak: Double) -> Double {
        guard peak > floor else { return 0.5 }
        return min(1, max(0, (average - floor) / (peak - floor)))
    }
}
