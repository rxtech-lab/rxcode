//
//  Item.swift
//  RxCodeMobile
//
//  Created by Qiwei Li on 5/19/26.
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
