//
//  RxCodeWidgetBundle.swift
//  RxCodeWidget
//
//  Created by Qiwei Li on 5/20/26.
//

import WidgetKit
import SwiftUI

@main
struct RxCodeWidgetBundle: WidgetBundle {
    var body: some Widget {
        RxCodeWidget()
        RxCodeWidgetLiveActivity()
    }
}
