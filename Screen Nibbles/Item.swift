//
//  Item.swift
//  Screen Nibbles
//
//  Created by Chih Hao Lin on 8/19/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
