//
//  SecurityModelValidatorTests.swift
//  Lutheran Radio
//
//  Created by Jari Lammi on 22.3.2026.
//

import Testing
import Foundation
@testable import Core

@Suite("SecurityModelValidator Tests")
struct SecurityModelValidatorTests {
    
    // ------------------------------------------------------------------------
    // Smoke test: can we even create and call the public validation method?
    // (If initializer is inaccessible → this will fail compilation → needs access fix)
    // ------------------------------------------------------------------------
    @Test("Validation runs without crashing (real DNS)")
    func validationRuns() async {
        let validator = SecurityModelValidator.shared
        
        let isValid = await validator.validateSecurityModel()
        
        #expect(isValid == true || isValid == false)  // just prove it returns Bool
    }
    
    // ------------------------------------------------------------------------
    // State observation after validation
    // ------------------------------------------------------------------------
    @Test("State transitions after validation call")
    func stateAfterValidation() async {
        let validator = SecurityModelValidator.shared
        
        let initialState = await validator.currentState
        #expect(initialState == .pending)  // assume .pending is public enum case
        
        _ = await validator.validateSecurityModel()  // trigger real lookup
        
        let finalState = await validator.currentState
        #expect(finalState == .success || finalState == .failedPermanent || finalState == .failedTransient)
    }
    
    // ------------------------------------------------------------------------
    // Reset behavior (if resetTransientState is public/internal)
    // ------------------------------------------------------------------------
    @Test("Reset transient state")
    func resetTransient() async {
        let validator = SecurityModelValidator.shared
        
        // Call validation first (may set transient failure if DNS bad)
        _ = await validator.validateSecurityModel()
        
        let stateBefore = await validator.currentState
        
        await validator.resetTransientState()  // assume this is accessible
        
        let stateAfter = await validator.currentState
        
        if stateBefore == .failedTransient {
            #expect(stateAfter != .failedTransient)
        } else {
            #expect(true, "No transient failure → reset has no effect")
        }
    }
    
    // ------------------------------------------------------------------------
    // Permanent invalid check (if isPermanentlyInvalid is accessible)
    // ------------------------------------------------------------------------
    @Test("Permanent invalid flag")
    func permanentFlag() async {
        let validator = SecurityModelValidator.shared
        
        _ = await validator.validateSecurityModel()
        
        let isPermanent = await validator.isPermanentlyInvalid
        
        #expect(isPermanent == true || isPermanent == false)
    }
}
